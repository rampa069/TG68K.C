------------------------------------------------------------------------------
-- TG68K.C 68040 FPU: arithmetic unit
--
-- A small sequential unit for the operations the MC68040 FPU performs in
-- hardware (M68040 User's Manual, section 9): move with rounding, FABS,
-- FNEG, FSQRT, FADD, FSUB, FMUL, FDIV, FCMP, FTST, and the conversion of an
-- extended value to an integer. Operands and results are 80-bit extended
-- values as held in FP0-FP7. Denormalized and unnormalized operands are
-- normalized and tiny results are denormalized here, so nothing is left to
-- the M68040FPSP that the 68040 would trap for.
--
-- Intermediate result (68040 UM figure 9-7): sign, 18-bit two's complement
-- exponent and a 68-bit mantissa m: m(67) overflow, m(66) integer bit,
-- m(65..3) fraction, m(2) guard, m(1) round, m(0) sticky. The result is
-- rounded at bit 3 (extended), 14 (double) or 43 (single), within the
-- exponent range of that precision.
--
-- One operation at a time: start with op, rounding mode and precision and
-- the operands (dst is FPn, src the source); done is set for one cycle with
-- result and the FPSR EXC bits it sets (snan operr ovfl unfl dz inex2).
--
-- op   0 move   1 abs   2 neg   3 sqrt   4 add   5 sub   6 mul   7 div
--      8 cmp    9 tst   10 to integer (size in rprec: 0 byte, 1 word,
--                          2 long; the integer is in result(31..0))
-- rprec  0 extended, 1 single, 2 double; to_mem keeps a denormal result of
--        single or double precision as a denormal (for a memory store),
--        where a register keeps it normalized.
--
-- Copyright (c) 2026 Ramon Martinez. LGPL-3.0-or-later, as TG68K.C.
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K_FPU_ALU is
	port (
		clk     : in  std_logic;
		reset   : in  std_logic;
		start   : in  std_logic;
		op      : in  std_logic_vector(3 downto 0);
		rmode   : in  std_logic_vector(1 downto 0);
		rprec   : in  std_logic_vector(1 downto 0);
		to_mem  : in  std_logic;
		dst     : in  std_logic_vector(79 downto 0);
		src     : in  std_logic_vector(79 downto 0);
		busy    : out std_logic;
		done    : out std_logic;
		result  : out std_logic_vector(79 downto 0);
		exc     : out std_logic_vector(5 downto 0)	-- snan operr ovfl unfl dz inex2
	);
end entity;

architecture rtl of TG68K_FPU_ALU is
	constant OP_MOVE : integer := 0;
	constant OP_ABS  : integer := 1;
	constant OP_NEG  : integer := 2;
	constant OP_SQRT : integer := 3;
	constant OP_ADD  : integer := 4;
	constant OP_SUB  : integer := 5;
	constant OP_MUL  : integer := 6;
	constant OP_DIV  : integer := 7;
	constant OP_CMP  : integer := 8;
	constant OP_TST  : integer := 9;
	constant OP_INT  : integer := 10;

	constant BIAS : integer := 16383;
	constant DEFAULT_NAN : std_logic_vector(79 downto 0) := x"7FFF" & x"FFFFFFFFFFFFFFFF";

	type state_t is (IDLE, NORM_A, NORM_B, DISPATCH, ALIGN, ADDSUB, MUL_LOOP, DIV_LOOP,
					 SQRT_LOOP, DIV_END, SQRT_END, NORMALIZE, DENORM, RND, POSTRND, RENORM, PACK, INT_PACK, FINISH);
	signal state : state_t := IDLE;

	signal opi : integer range 0 to 15;
	signal rm  : std_logic_vector(1 downto 0);
	signal pr  : std_logic_vector(1 downto 0);
	signal tomem : std_logic;

	-- operands: a = dst, b = src
	signal raw_a, raw_b : std_logic_vector(79 downto 0);
	signal sa, sb : std_logic;
	signal ea, eb : signed(17 downto 0);
	signal ma, mb : unsigned(63 downto 0);
	signal za, zb, ia, ib, na, nb : std_logic;		-- zero, infinity, NaN

	-- intermediate result
	signal s_r : std_logic;
	signal e_r : signed(17 downto 0);
	signal m_r : unsigned(67 downto 0);
	signal emin, emax : signed(17 downto 0);
	signal tiny : std_logic;

	-- addition
	signal msm : unsigned(67 downto 0);
	signal d_r : signed(17 downto 0);
	signal sub_r : std_logic;
	-- multiplication
	signal acc : unsigned(63 downto 0);
	signal mbs : unsigned(63 downto 0);
	signal mstk : std_logic;
	-- division and square root
	signal rem_d : unsigned(64 downto 0);
	signal rem_s : unsigned(70 downto 0);
	signal rad : unsigned(133 downto 0);
	signal root : unsigned(66 downto 0);
	signal cnt : integer range 0 to 127;

	signal x_snan, x_operr, x_ovfl, x_unfl, x_dz, x_inex : std_logic;
	signal res : std_logic_vector(79 downto 0);
	signal done_r : std_logic;

	function lsb_of(p : std_logic_vector(1 downto 0)) return integer is
	begin
		case p is
			when "01" => return 43;		-- single: 24 bits
			when "10" => return 14;		-- double: 53 bits
			when others => return 3;		-- extended: 64 bits
		end case;
	end function;
begin
	busy <= '0' when state = IDLE else '1';
	done <= done_r;
	result <= res;
	exc <= x_snan & x_operr & x_ovfl & x_unfl & x_dz & x_inex;

	process (clk)
		variable e18 : signed(17 downto 0);
		variable t73 : unsigned(72 downto 0);
		variable l : integer range 0 to 66;
		variable g, stk, up, inx : std_logic;
		variable mask : unsigned(67 downto 0);
		variable sbe : std_logic;
		variable a_big : boolean;
		variable trial : unsigned(70 downto 0);
		variable r71 : unsigned(70 downto 0);
		variable bexp : signed(17 downto 0);
		variable lim : unsigned(63 downto 0);
		variable ival : unsigned(63 downto 0);
		variable nsgn : std_logic;
	begin
		if rising_edge(clk) then
			done_r <= '0';
			if reset = '1' then
				state <= IDLE;
			else
				case state is
				when IDLE =>
					if start = '1' then
						opi <= to_integer(unsigned(op));
						rm <= rmode;
						pr <= rprec;
						tomem <= to_mem;
						raw_a <= dst;
						raw_b <= src;
						x_snan <= '0'; x_operr <= '0'; x_ovfl <= '0';
						x_unfl <= '0'; x_dz <= '0'; x_inex <= '0';
						tiny <= '0';
						-- unpack both operands
						sa <= dst(79);
						sb <= src(79);
						ma <= unsigned(dst(63 downto 0));
						mb <= unsigned(src(63 downto 0));
						if dst(78 downto 64) = "000000000000000" then
							ea <= to_signed(1 - BIAS, 18);
						else
							ea <= signed("000" & dst(78 downto 64)) - BIAS;
						end if;
						if src(78 downto 64) = "000000000000000" then
							eb <= to_signed(1 - BIAS, 18);
						else
							eb <= signed("000" & src(78 downto 64)) - BIAS;
						end if;
						if dst(78 downto 64) = "111111111111111" then
							za <= '0';
							if dst(62 downto 0) = (62 downto 0 => '0') then
								ia <= '1'; na <= '0';
							else
								ia <= '0'; na <= '1';
							end if;
						else
							ia <= '0'; na <= '0';
							if dst(63 downto 0) = x"0000000000000000" then za <= '1'; else za <= '0'; end if;
						end if;
						if src(78 downto 64) = "111111111111111" then
							zb <= '0';
							if src(62 downto 0) = (62 downto 0 => '0') then
								ib <= '1'; nb <= '0';
							else
								ib <= '0'; nb <= '1';
							end if;
						else
							ib <= '0'; nb <= '0';
							if src(63 downto 0) = x"0000000000000000" then zb <= '1'; else zb <= '0'; end if;
						end if;
						state <= NORM_A;
					end if;

				-- normalize denormal and unnormal operands, 8 or 1 bits a cycle
				when NORM_A =>
					if za = '1' or ia = '1' or na = '1' or ma(63) = '1' then
						state <= NORM_B;
					elsif ma(63 downto 56) = x"00" then
						ma <= ma(55 downto 0) & x"00";
						ea <= ea - 8;
					else
						ma <= ma(62 downto 0) & '0';
						ea <= ea - 1;
					end if;
				when NORM_B =>
					if zb = '1' or ib = '1' or nb = '1' or mb(63) = '1' then
						state <= DISPATCH;
					elsif mb(63 downto 56) = x"00" then
						mb <= mb(55 downto 0) & x"00";
						eb <= eb - 8;
					else
						mb <= mb(62 downto 0) & '0';
						eb <= eb - 1;
					end if;

				-- special operands, or the start of the arithmetic
				when DISPATCH =>
					-- precision limits (also the to-integer range: e = 63)
					case pr is
						when "01" => emin <= to_signed(-126, 18); emax <= to_signed(127, 18);
						when "10" => emin <= to_signed(-1022, 18); emax <= to_signed(1023, 18);
						when others => emin <= to_signed(-16382, 18); emax <= to_signed(16383, 18);
					end case;
					if opi = OP_INT then
						emin <= to_signed(63, 18);
						emax <= to_signed(63, 18);
					end if;
					if opi = OP_SUB then sbe := not sb; else sbe := sb; end if;
					state <= FINISH;
					done_r <= '1';
					-- NaN operands: the destination NaN, else the source, quieted;
					-- an SNaN sets SNAN (68040 UM 9.7.2)
					if (opi = OP_ADD or opi = OP_SUB or opi = OP_MUL or opi = OP_DIV or opi = OP_CMP) and
					   (na = '1' or nb = '1') then
						x_snan <= (na and not raw_a(62)) or (nb and not raw_b(62));
						if na = '1' then
							res <= raw_a(79 downto 63) & '1' & raw_a(61 downto 0);
						else
							res <= raw_b(79 downto 63) & '1' & raw_b(61 downto 0);
						end if;
					elsif nb = '1' then
						x_snan <= not raw_b(62);
						res <= raw_b(79 downto 63) & '1' & raw_b(61 downto 0);
						if opi = OP_INT then
							-- the most significant bits of the quieted mantissa, as the
							-- M68040FPSP stores them (68040 UM 9.7.2.2)
							x_operr <= '1';
							res(31 downto 0) <= raw_b(63) & '1' & raw_b(61 downto 32);
							if pr = "01" then
								res(15 downto 0) <= raw_b(63) & '1' & raw_b(61 downto 48);
							elsif pr = "00" then
								res(7 downto 0) <= raw_b(63) & '1' & raw_b(61 downto 56);
							end if;
						end if;
					else
						case opi is
						when OP_MOVE | OP_ABS | OP_NEG | OP_TST =>
							if opi = OP_ABS then nsgn := '0';
							elsif opi = OP_NEG then nsgn := not sb;
							else nsgn := sb; end if;
							if ib = '1' then
								res <= nsgn & "111111111111111" & x"0000000000000000";
							elsif zb = '1' then
								res <= nsgn & "000000000000000" & x"0000000000000000";
							elsif opi = OP_TST then
								res <= raw_b;
							else
								s_r <= nsgn; e_r <= eb; m_r <= "0" & mb & "000";
								state <= NORMALIZE; done_r <= '0';
							end if;
						when OP_INT =>
							if ib = '1' then
								-- out of range: INT_PACK saturates and sets OPERR
								s_r <= sb; e_r <= to_signed(1000, 18);
								m_r <= (66 => '1', others => '0');
								state <= INT_PACK; done_r <= '0';
							elsif zb = '1' then
								res <= (others => '0');
							else
								s_r <= sb; e_r <= eb; m_r <= "0" & mb & "000";
								state <= NORMALIZE; done_r <= '0';
							end if;
						when OP_SQRT =>
							if zb = '1' then
								res <= sb & "000000000000000" & x"0000000000000000";
							elsif sb = '1' then
								x_operr <= '1'; res <= DEFAULT_NAN;
							elsif ib = '1' then
								res <= '0' & "111111111111111" & x"0000000000000000";
							else
								s_r <= '0';
								e_r <= shift_right(eb, 1);
								if eb(0) = '1' then
									rad <= mb & to_unsigned(0, 70);
								else
									rad <= '0' & mb & to_unsigned(0, 69);
								end if;
								rem_s <= (others => '0');
								root <= (others => '0');
								cnt <= 0;
								state <= SQRT_LOOP; done_r <= '0';
							end if;
						when OP_ADD | OP_SUB =>
							if ia = '1' and ib = '1' and sa /= sbe then
								x_operr <= '1'; res <= DEFAULT_NAN;
							elsif ia = '1' then
								res <= sa & "111111111111111" & x"0000000000000000";
							elsif ib = '1' then
								res <= sbe & "111111111111111" & x"0000000000000000";
							elsif za = '1' and zb = '1' then
								if sa = sbe then
									res <= sa & "000000000000000" & x"0000000000000000";
								elsif rm = "10" then
									res <= '1' & "000000000000000" & x"0000000000000000";
								else
									res <= '0' & "000000000000000" & x"0000000000000000";
								end if;
							elsif za = '1' then
								s_r <= sbe; e_r <= eb; m_r <= "0" & mb & "000";
								state <= NORMALIZE; done_r <= '0';
							elsif zb = '1' then
								s_r <= sa; e_r <= ea; m_r <= "0" & ma & "000";
								state <= NORMALIZE; done_r <= '0';
							else
								a_big := ea > eb or (ea = eb and ma >= mb);
								if a_big then
									s_r <= sa; e_r <= ea; m_r <= "0" & ma & "000";
									msm <= "0" & mb & "000"; d_r <= ea - eb;
								else
									s_r <= sbe; e_r <= eb; m_r <= "0" & mb & "000";
									msm <= "0" & ma & "000"; d_r <= eb - ea;
								end if;
								sub_r <= sa xor sbe;
								state <= ALIGN; done_r <= '0';
							end if;
						when OP_MUL =>
							if (za = '1' and ib = '1') or (ia = '1' and zb = '1') then
								x_operr <= '1'; res <= DEFAULT_NAN;
							elsif ia = '1' or ib = '1' then
								res <= (sa xor sb) & "111111111111111" & x"0000000000000000";
							elsif za = '1' or zb = '1' then
								res <= (sa xor sb) & "000000000000000" & x"0000000000000000";
							else
								s_r <= sa xor sb;
								e_r <= ea + eb;
								acc <= (others => '0');
								mbs <= mb;
								mstk <= '0';
								cnt <= 0;
								state <= MUL_LOOP; done_r <= '0';
							end if;
						when OP_DIV =>
							if (za = '1' and zb = '1') or (ia = '1' and ib = '1') then
								x_operr <= '1'; res <= DEFAULT_NAN;
							elsif ia = '1' then
								res <= (sa xor sb) & "111111111111111" & x"0000000000000000";
							elsif ib = '1' then
								res <= (sa xor sb) & "000000000000000" & x"0000000000000000";
							elsif zb = '1' then
								x_dz <= '1';
								res <= (sa xor sb) & "111111111111111" & x"0000000000000000";
							elsif za = '1' then
								res <= (sa xor sb) & "000000000000000" & x"0000000000000000";
							else
								s_r <= sa xor sb;
								if ma < mb then
									rem_d <= ma & '0';
									e_r <= ea - eb - 1;
								else
									rem_d <= '0' & ma;
									e_r <= ea - eb;
								end if;
								m_r <= (others => '0');
								cnt <= 0;
								state <= DIV_LOOP; done_r <= '0';
							end if;
						when OP_CMP =>
							-- condition codes of the PRM FCMP table (I always clear)
							if (za = '1' and zb = '1') or (ia = '1' and ib = '1' and sa = sb) then
								res <= sa & "000000000000000" & x"0000000000000000";
							else
								-- order: -inf < finite < +inf; equal finite values give Z
								if raw_a = raw_b and ia = '0' then
									res <= (others => '0');
								elsif ia = '1' then
									res <= sa & "011111111111111" & x"8000000000000000";
								elsif ib = '1' then
									res <= (not sb) & "011111111111111" & x"8000000000000000";
								elsif za = '1' then
									res <= (not sb) & "011111111111111" & x"8000000000000000";
								elsif zb = '1' then
									res <= sa & "011111111111111" & x"8000000000000000";
								elsif sa /= sb then
									res <= sa & "011111111111111" & x"8000000000000000";
								elsif ea = eb and ma = mb then
									res <= (others => '0');
								elsif (ea > eb or (ea = eb and ma > mb)) then
									-- |a| > |b|: a < b when both are negative
									res <= sa & "011111111111111" & x"8000000000000000";
								else
									res <= (not sa) & "011111111111111" & x"8000000000000000";
								end if;
							end if;
						when others =>
							res <= (others => '0');
						end case;
					end if;

				-- addition: align the smaller operand, 8 or 1 bits a cycle
				when ALIGN =>
					if d_r = 0 then
						state <= ADDSUB;
					elsif d_r > 70 then
						msm <= (0 => '1', others => '0');	-- only the sticky bit is left
						d_r <= (others => '0');
					elsif d_r >= 8 then
						msm <= x"00" & msm(67 downto 9) & (msm(0) or msm(8) or msm(7) or msm(6) or msm(5) or
														   msm(4) or msm(3) or msm(2) or msm(1));
						d_r <= d_r - 8;
					else
						msm <= '0' & msm(67 downto 2) & (msm(1) or msm(0));
						d_r <= d_r - 1;
					end if;
				when ADDSUB =>
					if sub_r = '1' then
						m_r <= m_r - msm;
						if m_r = msm then
							-- exact cancellation: +0, or -0 rounding toward minus infinity
							if rm = "10" then
								res <= '1' & "000000000000000" & x"0000000000000000";
							else
								res <= '0' & "000000000000000" & x"0000000000000000";
							end if;
							state <= FINISH;
							done_r <= '1';
						else
							state <= NORMALIZE;
						end if;
					else
						m_r <= m_r + msm;
						state <= NORMALIZE;
					end if;

				-- multiplication: 64 x 8 bits a cycle, least significant first;
				-- acc holds the product shifted right by 8 per cycle
				when MUL_LOOP =>
					t73 := resize(acc, 73) + resize(ma * mbs(7 downto 0), 73);
					acc <= t73(71 downto 8);
					mbs <= x"00" & mbs(63 downto 8);
					if cnt = 7 then
						m_r <= t73(71 downto 8) & t73(7) & t73(6) & t73(5) &
							   (t73(4) or t73(3) or t73(2) or t73(1) or t73(0) or mstk);
						state <= NORMALIZE;
					else
						if t73(7 downto 0) /= x"00" then
							mstk <= '1';
						end if;
						cnt <= cnt + 1;
					end if;

				-- division: one quotient bit a cycle, weights 2^0 to 2^-66
				when DIV_LOOP =>
					if rem_d >= ('0' & mb) then
						m_r <= m_r(66 downto 0) & '1';
						rem_d <= (rem_d(63 downto 0) - mb) & '0';
					else
						m_r <= m_r(66 downto 0) & '0';
						rem_d <= rem_d(63 downto 0) & '0';
					end if;
					if cnt = 66 then
						state <= DIV_END;
					else
						cnt <= cnt + 1;
					end if;
				when DIV_END =>		-- a non-zero remainder is sticky
					if rem_d /= (64 downto 0 => '0') then
						m_r(0) <= '1';
					end if;
					state <= NORMALIZE;

				-- square root: one root bit a cycle, weights 2^0 to 2^-66
				when SQRT_LOOP =>
					r71 := rem_s(68 downto 0) & rad(133 downto 132);
					trial := resize(root & "01", 71);
					rad <= rad(131 downto 0) & "00";
					if r71 >= trial then
						rem_s <= r71 - trial;
						root <= root(65 downto 0) & '1';
					else
						rem_s <= r71;
						root <= root(65 downto 0) & '0';
					end if;
					if cnt = 66 then
						state <= SQRT_END;
					else
						cnt <= cnt + 1;
					end if;
				when SQRT_END =>		-- a non-zero remainder is sticky
					m_r <= '0' & root;
					if rem_s /= (70 downto 0 => '0') then
						m_r(0) <= '1';
					end if;
					state <= NORMALIZE;

				-- bring the integer bit to m(66)
				when NORMALIZE =>
					if m_r = (67 downto 0 => '0') then
						state <= PACK;
					elsif m_r(67) = '1' then
						m_r <= '0' & m_r(67 downto 2) & (m_r(1) or m_r(0));
						e_r <= e_r + 1;
					elsif m_r(66) = '1' then
						state <= DENORM;
					elsif m_r(66 downto 59) = x"00" then
						m_r <= m_r(59 downto 0) & x"00";
						e_r <= e_r - 8;
					else
						m_r <= m_r(66 downto 0) & '0';
						e_r <= e_r - 1;
					end if;

				-- a tiny result is shifted right to the minimum exponent
				when DENORM =>
					if e_r >= emin then
						state <= RND;
					else
						if opi /= OP_INT then
							tiny <= '1';
						end if;
						if emin - e_r > 70 then
							m_r <= (0 => (m_r(0) or '1'), others => '0');
							e_r <= emin;
						elsif emin - e_r >= 8 then
							m_r <= x"00" & m_r(67 downto 9) & (m_r(0) or m_r(8) or m_r(7) or m_r(6) or m_r(5) or
															   m_r(4) or m_r(3) or m_r(2) or m_r(1));
							e_r <= e_r + 8;
						else
							m_r <= '0' & m_r(67 downto 2) & (m_r(1) or m_r(0));
							e_r <= e_r + 1;
						end if;
					end if;

				-- round at the precision's last bit
				when RND =>
					if opi = OP_INT then l := 3; else l := lsb_of(pr); end if;
					g := m_r(l - 1);
					stk := '0';
					for i in 0 to 66 loop
						if i < l - 1 and m_r(i) = '1' then
							stk := '1';
						end if;
					end loop;
					inx := g or stk;
					case rm is
						when "00" => up := g and (stk or m_r(l));
						when "01" => up := '0';
						when "10" => up := inx and s_r;
						when others => up := inx and not s_r;
					end case;
					mask := (others => '1');
					for i in 0 to 66 loop
						if i < l then
							mask(i) := '0';
						end if;
					end loop;
					if up = '1' then
						m_r <= (m_r and mask) + shift_left(to_unsigned(1, 68), l);
					else
						m_r <= m_r and mask;
					end if;
					if inx = '1' then
						x_inex <= '1';
					end if;
					if tiny = '1' then
						x_unfl <= '1';
					end if;
					state <= POSTRND;

				when POSTRND =>
					if m_r(67) = '1' then
						m_r <= '0' & m_r(67 downto 1);
						e_r <= e_r + 1;
					end if;
					state <= PACK;
					if opi = OP_INT then
						state <= INT_PACK;
					end if;

				-- store the result as an extended value
				when PACK =>
					done_r <= '1';
					state <= FINISH;
					if m_r(66 downto 0) = (66 downto 0 => '0') then
						res <= s_r & "000000000000000" & x"0000000000000000";
					elsif e_r > emax then
						x_ovfl <= '1';
						x_inex <= '1';
						if rm = "00" or (rm = "10" and s_r = '1') or (rm = "11" and s_r = '0') then
							res <= s_r & "111111111111111" & x"0000000000000000";
						else
							-- largest number of the precision
							bexp := emax + BIAS;
							case pr is
								when "01" => res <= s_r & std_logic_vector(bexp(14 downto 0)) & x"FFFFFF0000000000";
								when "10" => res <= s_r & std_logic_vector(bexp(14 downto 0)) & x"FFFFFFFFFFFFF800";
								when others => res <= s_r & std_logic_vector(bexp(14 downto 0)) & x"FFFFFFFFFFFFFFFF";
							end case;
						end if;
					elsif m_r(66) = '1' then
						bexp := e_r + BIAS;
						res <= s_r & std_logic_vector(bexp(14 downto 0)) & std_logic_vector(m_r(66 downto 3));
					elsif pr = "00" or tomem = '1' then
						-- denormal at the precision's minimum exponent
						if pr = "00" then
							res <= s_r & "000000000000000" & std_logic_vector(m_r(66 downto 3));
						else
							bexp := e_r + BIAS;
							res <= s_r & std_logic_vector(bexp(14 downto 0)) & std_logic_vector(m_r(66 downto 3));
						end if;
					else
						-- a single or double denormal is a normal extended number
						done_r <= '0';
						state <= RENORM;
					end if;
				when RENORM =>
					if m_r(66) = '1' then
						bexp := e_r + BIAS;
						res <= s_r & std_logic_vector(bexp(14 downto 0)) & std_logic_vector(m_r(66 downto 3));
						done_r <= '1';
						state <= FINISH;
					else
						m_r <= m_r(66 downto 0) & '0';
						e_r <= e_r - 1;
					end if;

				-- integer result: magnitude in m(66..3), range by size
				when INT_PACK =>
					done_r <= '1';
					state <= FINISH;
					ival := m_r(66 downto 3);
					case pr is
						when "00" => if s_r = '1' then lim := x"0000000000000080"; else lim := x"000000000000007F"; end if;
						when "01" => if s_r = '1' then lim := x"0000000000008000"; else lim := x"0000000000007FFF"; end if;
						when others => if s_r = '1' then lim := x"0000000080000000"; else lim := x"000000007FFFFFFF"; end if;
					end case;
					if e_r > emax or ival > lim then
						-- saturate: the largest integer of the sign (for a negative
						-- value lim is already the pattern of -2^(n-1))
						x_operr <= '1';
						x_inex <= '0';
						res <= x"0000" & x"00000000" & std_logic_vector(lim(31 downto 0));
					elsif s_r = '1' then
						res <= x"0000" & std_logic_vector(0 - ival);
					else
						res <= x"0000" & std_logic_vector(ival);
					end if;

				when FINISH =>
					state <= IDLE;
				end case;
			end if;
		end if;
	end process;
end architecture;
