------------------------------------------------------------------------------
-- TG68K.C 68040 FPU
--
-- The floating-point unit of the 68040 mode (CPU = "10"): FP0-FP7, FPCR,
-- FPSR and FPIAR, the conversion between the memory data formats and the
-- extended format, a bus sequencer for the memory operands and the
-- arithmetic unit TG68K_FPU_ALU. The kernel decodes the F-line opcode,
-- works out the effective address of the memory modes it shares with the
-- integer unit ((d16,An), (d8,An,Xn), absolute and PC-relative), gives the
-- address of immediate data, then starts this unit and waits for done.
--
-- Instructions (M68000 PRM section 5, M68040 User's Manual section 9):
--   cpGEN  opclass 000 FPm,FPn and 010 <ea>,FPn: FMOVE, FSQRT, FABS, FNEG,
--          FDIV, FADD, FMUL, FSUB, FCMP, FTST and their FS/FD forms
--          opclass 011 FMOVE FPn,<ea> (B W L S D X)
--          opclass 100/101 FMOVE(M) <ea>,FPcr and FPcr,<ea>
--          opclass 110/111 FMOVEM <ea>,list and list,<ea>
--   FScc, FDBcc
--   FSAVE (null or idle frame), FRESTORE
-- The operations the 68040 leaves to the M68040FPSP (the transcendental
-- functions, FINT, FINTRZ, FGETEXP, FGETMAN, FMOD, FREM, FSCALE, FSGL*) are
-- done as the 68040 does them (UM 9.6): the source operand is fetched and
-- converted, unimp is set with done, and the kernel takes the unimplemented
-- floating-point instruction exception (vector 11, format $2); the FSAVE
-- of the FPSP then gets the 26-word unimplemented instruction frame with
-- the command word, the source (ETEMP), the destination register (FPTEMP)
-- and their tags. FMOVECR and packed decimal are recognized by the kernel,
-- which takes Line-F with a format $0 frame (the FPSP emulates FMOVECR from
-- that). Immediate data is read like a
-- memory operand at the address the kernel gives. FPCR exception enables
-- are kept but never trap.
--
-- Copyright (c) 2026 Ramon Martinez. LGPL-3.0-or-later, as TG68K.C.
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K_FPU is
	port (
		clk       : in  std_logic;
		reset     : in  std_logic;
		clkena    : in  std_logic;
		-- instruction
		start     : in  std_logic;
		opcode    : in  std_logic_vector(15 downto 0);
		cmd       : in  std_logic_vector(15 downto 0);
		ea        : in  std_logic_vector(31 downto 0);	-- modes 5, 6, 7: the operand address
																-- (for #imm, where the data starts)
		iaddr     : in  std_logic_vector(31 downto 0);	-- address of the instruction (FPIAR)
		done      : out std_logic;
		unimp     : out std_logic;					-- with done: unimplemented, take vector 11
		ea_out    : out std_logic_vector(31 downto 0);	-- the operand address, for that frame
		br_take   : out std_logic;					-- with done: FDBcc branches
		br_target : out std_logic_vector(31 downto 0);
		-- integer register file
		rd_idx    : out integer range 0 to 15;
		rd_data   : in  std_logic_vector(31 downto 0);
		wr_en     : out std_logic;
		wr_idx    : out integer range 0 to 15;
		wr_data   : out std_logic_vector(31 downto 0);
		wr_size   : out std_logic_vector(1 downto 0);	-- 00 byte, 01 word, 10 long
		-- bus
		bus_act   : out std_logic;
		bus_addr  : out std_logic_vector(31 downto 0);
		bus_wr    : out std_logic;
		bus_uds_n : out std_logic;
		bus_lds_n : out std_logic;
		bus_wdata : out std_logic_vector(15 downto 0);
		data_in   : in  std_logic_vector(15 downto 0);
		-- conditional predicates (FBcc, FScc, FDBcc, FTRAPcc)
		pred      : in  std_logic_vector(5 downto 0);
		pred_true : out std_logic
	);
end entity;

architecture rtl of TG68K_FPU is
	type fpregs_t is array (0 to 7) of std_logic_vector(79 downto 0);
	type bytes_t is array (0 to 11) of std_logic_vector(7 downto 0);
	type frame_t is array (0 to 51) of std_logic_vector(7 downto 0);
	constant FP_NAN : std_logic_vector(79 downto 0) := x"7FFF" & x"FFFFFFFFFFFFFFFF";

	signal fpr : fpregs_t := (others => FP_NAN);
	signal fpcr : std_logic_vector(15 downto 0) := (others => '0');
	signal fpsr : std_logic_vector(31 downto 0) := (others => '0');
	signal fpiar : std_logic_vector(31 downto 0) := (others => '0');
	signal null_state : std_logic := '1';

	type state_t is (IDLE, ST_REG, ST_EA, ST_SRC, ST_XFER, ST_XFER_DONE, ST_ALU, ST_ALU_WAIT,
					 ST_STORE, ST_CTRL, ST_MOVEM, ST_MOVEM_W, ST_RESTORE, ST_DBCC, ST_UNIMP, ST_LIST, ST_FINISH);
	signal state : state_t := IDLE;
	signal ret_state : state_t;

	-- the instruction
	signal opc, cw : std_logic_vector(15 downto 0);
	signal mode, reg : std_logic_vector(2 downto 0);
	signal cls : std_logic_vector(2 downto 0);
	signal fmt : std_logic_vector(2 downto 0);
	signal addr : unsigned(31 downto 0);
	signal areg : std_logic_vector(31 downto 0);
	signal nbytes : integer range 0 to 255;

	-- bus sequencer: transfer xn bytes between buf and memory at xa
	signal buf : bytes_t;
	signal xa : unsigned(31 downto 0);
	signal xi, xn : integer range 0 to 52;
	signal xframe : std_logic := '0';		-- FSAVE: the data comes from the unimp frame
	signal xwr : std_logic;
	signal xbyte : std_logic;			-- the current cycle moves one byte

	-- arithmetic unit
	signal alu_start, alu_busy, alu_done, alu_tomem : std_logic;
	signal alu_op : std_logic_vector(3 downto 0);
	signal alu_rm, alu_rp : std_logic_vector(1 downto 0);
	signal alu_dst, alu_src, alu_res : std_logic_vector(79 downto 0);
	signal alu_exc : std_logic_vector(5 downto 0);
	signal srcx : std_logic_vector(79 downto 0);
	signal wr_fp : std_logic;			-- write the result to FPn
	signal set_cc : std_logic;
	signal store : std_logic;			-- opclass 011

	-- FMOVEM
	signal list : std_logic_vector(7 downto 0);
	signal li : integer range 0 to 8;
	signal mptr : unsigned(31 downto 0);

	signal done_r, unimp_r : std_logic := '0';
	-- the pending unimplemented instruction, for the FSAVE frame
	signal unimp_pend : std_logic := '0';
	signal uop : std_logic;
	signal etemp, fptemp : std_logic_vector(79 downto 0);
	signal cmd1b : std_logic_vector(15 downto 0);
	signal ufr : frame_t;
	signal br_r : std_logic := '0';
	signal brt : unsigned(31 downto 0);

	-- memory formats to extended (an unnormal extended value is fine: the
	-- arithmetic unit normalizes it)
	function int_to_x(v : signed(31 downto 0)) return std_logic_vector is
		variable m : unsigned(31 downto 0);
	begin
		if v = 0 then
			return (79 downto 0 => '0');
		end if;
		if v < 0 then m := unsigned(-v); else m := unsigned(v); end if;
		return std_logic(v(31)) & std_logic_vector(to_unsigned(16383 + 63, 15)) &
			   x"00000000" & std_logic_vector(m);
	end function;

	function sgl_to_x(s : std_logic_vector(31 downto 0)) return std_logic_vector is
		variable e : unsigned(14 downto 0);
	begin
		if s(30 downto 23) = x"FF" then
			return s(31) & "111111111111111" & '1' & s(22 downto 0) & x"0000000000";
		elsif s(30 downto 23) = x"00" then
			if s(22 downto 0) = (22 downto 0 => '0') then
				return s(31) & (78 downto 0 => '0');
			end if;
			-- denormal: 0.f x 2^-126, an unnormal extended value
			return s(31) & std_logic_vector(to_unsigned(16383 - 126, 15)) & '0' & s(22 downto 0) & x"0000000000";
		end if;
		e := resize(unsigned(s(30 downto 23)), 15) + (16383 - 127);
		return s(31) & std_logic_vector(e) & '1' & s(22 downto 0) & x"0000000000";
	end function;

	function dbl_to_x(d : std_logic_vector(63 downto 0)) return std_logic_vector is
		variable e : unsigned(14 downto 0);
	begin
		if d(62 downto 52) = "11111111111" then
			return d(63) & "111111111111111" & '1' & d(51 downto 0) & "00000000000";
		elsif d(62 downto 52) = "00000000000" then
			if d(51 downto 0) = (51 downto 0 => '0') then
				return d(63) & (78 downto 0 => '0');
			end if;
			return d(63) & std_logic_vector(to_unsigned(16383 - 1022, 15)) & '0' & d(51 downto 0) & "00000000000";
		end if;
		e := resize(unsigned(d(62 downto 52)), 15) + (16383 - 1023);
		return d(63) & std_logic_vector(e) & '1' & d(51 downto 0) & "00000000000";
	end function;

	-- extended (rounded to single or double with to_mem) to memory formats
	function x_to_sgl(x : std_logic_vector(79 downto 0)) return std_logic_vector is
		variable e : unsigned(14 downto 0);
	begin
		if x(78 downto 64) = "111111111111111" then
			return x(79) & x"FF" & x(62 downto 40);
		elsif x(63) = '0' then		-- zero or a denormal
			return x(79) & x"00" & x(62 downto 40);
		end if;
		e := unsigned(x(78 downto 64)) - (16383 - 127);
		return x(79) & std_logic_vector(e(7 downto 0)) & x(62 downto 40);
	end function;

	function x_to_dbl(x : std_logic_vector(79 downto 0)) return std_logic_vector is
		variable e : unsigned(14 downto 0);
	begin
		if x(78 downto 64) = "111111111111111" then
			return x(79) & "11111111111" & x(62 downto 11);
		elsif x(63) = '0' then
			return x(79) & "00000000000" & x(62 downto 11);
		end if;
		e := unsigned(x(78 downto 64)) - (16383 - 1023);
		return x(79) & std_logic_vector(e(10 downto 0)) & x(62 downto 11);
	end function;

	-- operand sizes of the formats: L S X P W D B
	function fmt_bytes(f : std_logic_vector(2 downto 0)) return integer is
	begin
		case f is
			when "000" | "001" => return 4;
			when "010" | "011" => return 12;
			when "100" => return 2;
			when "101" => return 8;
			when others => return 1;
		end case;
	end function;

	function popcount3(v : std_logic_vector(2 downto 0)) return integer is
		variable n : integer range 0 to 3 := 0;
	begin
		for i in 0 to 2 loop
			if v(i) = '1' then n := n + 1; end if;
		end loop;
		return n;
	end function;

	function popcount8(v : std_logic_vector(7 downto 0)) return integer is
		variable n : integer range 0 to 8 := 0;
	begin
		for i in 0 to 7 loop
			if v(i) = '1' then n := n + 1; end if;
		end loop;
		return n;
	end function;

	-- conditional predicates (M68000 PRM table 3-23) on N Z NAN of the FPCC;
	-- bit 4 only selects the signaling form
	function pred_eval(p : std_logic_vector(5 downto 0); n, z, nan : std_logic) return std_logic is
	begin
		case p(3 downto 0) is
			when "0000" => return '0';
			when "0001" => return z;
			when "0010" => return not (nan or z or n);
			when "0011" => return z or not (nan or n);
			when "0100" => return n and not (nan or z);
			when "0101" => return z or (n and not nan);
			when "0110" => return not (nan or z);
			when "0111" => return not nan;
			when "1000" => return nan;
			when "1001" => return nan or z;
			when "1010" => return nan or not (n or z);
			when "1011" => return nan or z or not n;
			when "1100" => return nan or (n and not z);
			when "1101" => return nan or z or n;
			when "1110" => return not z;
			when others => return '1';
		end case;
	end function;

	-- operand tags of the state frames (fpsp.h of the M68040FPSP): norm $00,
	-- zero $20, infinity $40, NaN $60, denormal $80, unnormal $A0
	function tag_of(x : std_logic_vector(79 downto 0)) return std_logic_vector is
	begin
		if x(78 downto 64) = "111111111111111" then
			if x(62 downto 0) = (62 downto 0 => '0') then return x"40"; end if;
			return x"60";
		elsif x(63 downto 0) = x"0000000000000000" then
			return x"20";
		elsif x(78 downto 64) = "000000000000000" then
			return x"80";
		elsif x(63) = '0' then
			return x"A0";
		end if;
		return x"00";
	end function;

	function buf_long(b : bytes_t; i : integer) return std_logic_vector is
	begin
		return b(i) & b(i + 1) & b(i + 2) & b(i + 3);
	end function;
begin
	done <= done_r;
	unimp <= unimp_r;
	ea_out <= std_logic_vector(addr);

	-- the 26-word unimplemented instruction frame (68040 UM figure 9-10;
	-- offsets from fpsp.h): version $41, size $30
	process (etemp, fptemp, cmd1b)
		variable f : frame_t;
	begin
		f := (others => x"00");
		f(0) := x"41"; f(1) := x"30";
		f(12) := tag_of(etemp);					-- STAG
		f(16) := cmd1b(15 downto 8); f(17) := cmd1b(7 downto 0);	-- CMDREG1B
		f(20) := tag_of(fptemp);				-- DTAG
		f(28) := fptemp(79 downto 72); f(29) := fptemp(71 downto 64);
		for i in 0 to 7 loop
			f(32 + i) := fptemp(63 - 8 * i downto 56 - 8 * i);
		end loop;
		f(40) := etemp(79 downto 72); f(41) := etemp(71 downto 64);
		for i in 0 to 7 loop
			f(44 + i) := etemp(63 - 8 * i downto 56 - 8 * i);
		end loop;
		ufr <= f;
	end process;
	br_take <= br_r;
	br_target <= std_logic_vector(brt);

	alu : entity work.TG68K_FPU_ALU
		port map (clk => clk, reset => reset, ena => clkena, start => alu_start, op => alu_op, rmode => alu_rm,
				  rprec => alu_rp, to_mem => alu_tomem, dst => alu_dst, src => alu_src,
				  busy => alu_busy, done => alu_done, result => alu_res, exc => alu_exc);

	pred_true <= pred_eval(pred, fpsr(27), fpsr(26), fpsr(24));

	-- the bus cycle of the sequencer
	bus_act <= '1' when state = ST_XFER else '0';
	bus_addr <= std_logic_vector(xa(31 downto 1)) & '0';
	bus_wr <= xwr;
	xbyte <= '1' when xa(0) = '1' or xn - xi = 1 else '0';
	bus_uds_n <= '1' when xbyte = '1' and xa(0) = '1' else '0';
	bus_lds_n <= '1' when xbyte = '1' and xa(0) = '0' else '0';
	process (xframe, xbyte, xi, ufr, buf)
	begin
		if xframe = '1' and xi < 51 then
			bus_wdata <= ufr(xi) & ufr(xi + 1);
		elsif xi > 11 then
			bus_wdata <= (others => '0');		-- not a transfer of buf
		elsif xbyte = '1' or xi = 11 then
			bus_wdata <= buf(xi) & buf(xi);
		else
			bus_wdata <= buf(xi) & buf(xi + 1);
		end if;
	end process;
	-- the An of the effective address, or Dn (also the counter of FDBcc)
	rd_idx <= to_integer(unsigned(cw(6 downto 4))) when state = ST_LIST else		-- FMOVEM dynamic list
			  to_integer(unsigned(reg)) when mode = "000" or (opc(8 downto 6) = "001" and mode = "001") else
			  8 + to_integer(unsigned(reg));

	process (clk)
		variable e : std_logic_vector(5 downto 0);
		variable opm : std_logic_vector(6 downto 0);
		variable ok : boolean;
		variable nb : integer range 0 to 255;
		variable x : std_logic_vector(79 downto 0);
		variable v32 : std_logic_vector(31 downto 0);
		variable v64 : std_logic_vector(63 downto 0);
		variable fpn : integer range 0 to 7;
		variable idx : integer range 0 to 11;
	begin
		if rising_edge(clk) then
			if reset = '1' then
				done_r <= '0';
				alu_start <= '0';
				wr_en <= '0';
				state <= IDLE;
				fpr <= (others => FP_NAN);
				fpcr <= (others => '0');
				fpsr <= (others => '0');
				fpiar <= (others => '0');
				null_state <= '1';
				unimp_pend <= '0';
				xframe <= '0';
			elsif clkena = '1' then
				done_r <= '0';
				unimp_r <= '0';
				alu_start <= '0';
				wr_en <= '0';
				case state is
				when IDLE =>
					br_r <= '0';
					if start = '1' then
						opc <= opcode;
						cw <= cmd;
						mode <= opcode(5 downto 3);
						reg <= opcode(2 downto 0);
						cls <= cmd(15 downto 13);
						fmt <= cmd(12 downto 10);
						wr_fp <= '0';
						set_cc <= '0';
						store <= '0';
						state <= ST_REG;
					end if;

				-- An or Dn of the effective address is on rd_data now
				when ST_REG =>
					areg <= rd_data;
					-- operand size in memory
					if opc(8 downto 6) = "100" and unimp_pend = '1' then
						nb := 52;								-- FSAVE, unimplemented frame
					elsif opc(8 downto 6) = "100" or opc(8 downto 6) = "101" then
						nb := 4;								-- FSAVE, FRESTORE header
					elsif opc(8 downto 6) = "001" then
						nb := 1;								-- FScc byte (FDBcc: none)
					elsif cls = "100" or cls = "101" then
						nb := 4 * popcount3(cw(12 downto 10));	-- control registers
					elsif cls = "110" or cls = "111" then
						-- static list (mode bit 11 clear), or one in Dn (ST_LIST)
						list <= cw(7 downto 0);
						nb := 12 * popcount8(cw(7 downto 0));
					else
						nb := fmt_bytes(cw(12 downto 10));
					end if;
					nbytes <= nb;
					state <= ST_EA;
					if (cls = "110" or cls = "111") and opc(8 downto 6) = "000" and cw(11) = '1' then
						state <= ST_LIST;
					end if;
				when ST_LIST =>
					-- FMOVEM with the register list in the low byte of Dn
					list <= rd_data(7 downto 0);
					nbytes <= 12 * popcount8(rd_data(7 downto 0));
					state <= ST_EA;

				-- the operand address, and the register update of (An)+ and -(An)
				when ST_EA =>
					nb := nbytes;
					if opc(8 downto 6) = "001" and mode = "001" then
						nb := 0;									-- FDBcc
					end if;
					case mode is
						when "010" => addr <= unsigned(areg);
						when "011" =>
							addr <= unsigned(areg);
							if reg = "111" and nb = 1 then nb := 2; end if;
							wr_en <= '1'; wr_idx <= 8 + to_integer(unsigned(reg));
							wr_size <= "10"; wr_data <= std_logic_vector(unsigned(areg) + nb);
						when "100" =>
							if reg = "111" and nb = 1 then nb := 2; end if;
							addr <= unsigned(areg) - nb;
							wr_en <= '1'; wr_idx <= 8 + to_integer(unsigned(reg));
							wr_size <= "10"; wr_data <= std_logic_vector(unsigned(areg) - nb);
						when others => addr <= unsigned(ea);
					end case;
					state <= ST_SRC;

				-- dispatch on the instruction
				when ST_SRC =>
					null_state <= '0';
					if opc(8 downto 6) = "001" then
						-- FScc and FDBcc: the predicate is in the extension word; a
						-- signaling predicate on a NaN sets BSUN (and AEXC IOP)
						null_state <= null_state;
						if cw(4) = '1' and fpsr(24) = '1' then
							fpsr(15) <= '1';
							fpsr(7) <= '1';
						end if;
						if pred_eval(cw(5 downto 0), fpsr(27), fpsr(26), fpsr(24)) = '1' then
							buf(0) <= x"FF";
						else
							buf(0) <= x"00";
						end if;
						if mode = "001" then
							-- FDBcc: when false, Dn.w - 1, and branch unless it is -1
							if pred_eval(cw(5 downto 0), fpsr(27), fpsr(26), fpsr(24)) = '1' then
								done_r <= '1'; state <= ST_FINISH;
							else
								wr_en <= '1'; wr_idx <= to_integer(unsigned(reg)); wr_size <= "01";
								wr_data <= std_logic_vector(unsigned(rd_data) - 1);
								if rd_data(15 downto 0) = x"0000" then
									done_r <= '1'; state <= ST_FINISH;
								else
									-- the displacement word, relative to its own address
									xa <= addr; xi <= 0; xn <= 2; xwr <= '0';
									state <= ST_XFER; ret_state <= ST_DBCC;
								end if;
							end if;
						elsif mode = "000" then
							wr_en <= '1'; wr_idx <= to_integer(unsigned(reg)); wr_size <= "00";
							if pred_eval(cw(5 downto 0), fpsr(27), fpsr(26), fpsr(24)) = '1' then
								wr_data <= x"000000FF";
							else
								wr_data <= x"00000000";
							end if;
							done_r <= '1'; state <= ST_FINISH;
						else
							xa <= addr; xi <= 0; xn <= 1; xwr <= '1';
							state <= ST_XFER; ret_state <= ST_FINISH;
						end if;
					elsif opc(8 downto 6) = "100" then
						-- FSAVE: a null frame until a non-conditional instruction ran,
						-- an idle frame after (68040 UM 9.8)
						if null_state = '1' then
							buf(0) <= x"00";
						else
							buf(0) <= x"41";
						end if;
						null_state <= null_state;
						buf(1) <= x"00"; buf(2) <= x"00"; buf(3) <= x"00";
						xa <= addr; xi <= 0; xn <= 4; xwr <= '1';
						if unimp_pend = '1' then
							xn <= 52;
							xframe <= '1';
							unimp_pend <= '0';
						end if;
						state <= ST_XFER; ret_state <= ST_FINISH;
					elsif opc(8 downto 6) = "101" then
						xa <= addr; xi <= 0; xn <= 4; xwr <= '0';
						state <= ST_XFER; ret_state <= ST_RESTORE;
					elsif cls = "000" or cls = "010" then
						opm := cw(6 downto 0);
						ok := true;
						case opm is
							when "0000000" | "1000000" | "1000100" => alu_op <= x"0";	-- FMOVE
							when "0011000" | "1011000" | "1011100" => alu_op <= x"1";	-- FABS
							when "0011010" | "1011010" | "1011110" => alu_op <= x"2";	-- FNEG
							when "0000100" | "1000001" | "1000101" => alu_op <= x"3";	-- FSQRT
							when "0100010" | "1100010" | "1100110" => alu_op <= x"4";	-- FADD
							when "0101000" | "1101000" | "1101100" => alu_op <= x"5";	-- FSUB
							when "0100011" | "1100011" | "1100111" => alu_op <= x"6";	-- FMUL
							when "0100000" | "1100000" | "1100100" => alu_op <= x"7";	-- FDIV
							when "0111000" => alu_op <= x"8";							-- FCMP
							when "0111010" => alu_op <= x"9";							-- FTST
							when others => ok := false;
						end case;
						-- an operation the 68040 leaves to the FPSP: the source is
						-- fetched and converted all the same (ST_UNIMP)
						if ok then uop <= '0'; else uop <= '1'; end if;
						ok := true;
						if cls = "010" and (fmt = "011" or fmt = "111") then
							ok := false;		-- packed decimal, FMOVECR: the kernel took Line-F
						end if;
						if not ok then
							done_r <= '1'; state <= ST_FINISH;
						else
							-- precision: the FS and FD forms, else FPCR PREC
							if opm(6) = '1' then
								if opm(2) = '1' then alu_rp <= "10"; else alu_rp <= "01"; end if;
							else
								alu_rp <= fpcr(7 downto 6);
							end if;
							alu_rm <= fpcr(5 downto 4);
							alu_tomem <= '0';
							fpn := to_integer(unsigned(cw(9 downto 7)));
							alu_dst <= fpr(fpn);
							if opm /= "0111000" and opm /= "0111010" then
								wr_fp <= '1';
							end if;
							set_cc <= '1';
							fpiar <= iaddr;
							if cls = "000" then
								alu_src <= fpr(to_integer(unsigned(cw(12 downto 10))));
								state <= ST_ALU;
							elsif mode = "000" then
								-- Dn: B W L S
								case fmt is
									when "000" => alu_src <= int_to_x(signed(rd_data));
									when "001" => alu_src <= sgl_to_x(rd_data);
									when "100" => alu_src <= int_to_x(resize(signed(rd_data(15 downto 0)), 32));
									when "110" => alu_src <= int_to_x(resize(signed(rd_data(7 downto 0)), 32));
									when others => ok := false;
								end case;
								if ok then
									state <= ST_ALU;
								else
									done_r <= '1'; state <= ST_FINISH;
								end if;
							else
								xa <= addr; xi <= 0; xn <= nbytes; xwr <= '0';
								state <= ST_XFER; ret_state <= ST_ALU;
							end if;
						end if;
					elsif cls = "011" then
						-- FMOVE FPn,<ea>
						fpn := to_integer(unsigned(cw(9 downto 7)));
						alu_src <= fpr(fpn);
						alu_dst <= fpr(fpn);
						alu_rm <= fpcr(5 downto 4);
						alu_tomem <= '1';
						store <= '1';
						fpiar <= iaddr;
						case fmt is
							when "000" => alu_op <= x"A"; alu_rp <= "10"; state <= ST_ALU;
							when "100" => alu_op <= x"A"; alu_rp <= "01"; state <= ST_ALU;
							when "110" => alu_op <= x"A"; alu_rp <= "00"; state <= ST_ALU;
							when "001" => alu_op <= x"0"; alu_rp <= "01"; state <= ST_ALU;
							when "101" => alu_op <= x"0"; alu_rp <= "10"; state <= ST_ALU;
							when "010" =>
								-- extended: a copy, no rounding
								x := fpr(fpn);
								buf(0) <= x(79 downto 72); buf(1) <= x(71 downto 64);
								buf(2) <= x"00"; buf(3) <= x"00";
								for i in 0 to 7 loop
									buf(4 + i) <= x(63 - 8 * i downto 56 - 8 * i);
								end loop;
								xa <= addr; xi <= 0; xn <= 12; xwr <= '1';
								state <= ST_XFER; ret_state <= ST_FINISH;
							when others =>
								done_r <= '1'; state <= ST_FINISH;
						end case;
					elsif cls = "100" then
						-- FMOVE(M) <ea>,FPCR/FPSR/FPIAR
						if mode = "000" or mode = "001" then
							for i in 0 to 3 loop
								buf(i) <= rd_data(31 - 8 * i downto 24 - 8 * i);
							end loop;
							state <= ST_XFER_DONE; ret_state <= ST_CTRL;
						else
							xa <= addr; xi <= 0; xn <= nbytes; xwr <= '0';
							state <= ST_XFER; ret_state <= ST_CTRL;
						end if;
					elsif cls = "101" then
						-- FMOVE(M) FPCR/FPSR/FPIAR,<ea>: in that order in memory
						idx := 0;
						if cw(12) = '1' then
							buf(0) <= x"00"; buf(1) <= x"00"; buf(2) <= fpcr(15 downto 8); buf(3) <= fpcr(7 downto 0);
							idx := 4;
						end if;
						if cw(11) = '1' then
							for i in 0 to 3 loop
								buf(idx + i) <= fpsr(31 - 8 * i downto 24 - 8 * i);
							end loop;
							idx := idx + 4;
						end if;
						if cw(10) = '1' then
							for i in 0 to 3 loop
								buf(idx + i) <= fpiar(31 - 8 * i downto 24 - 8 * i);
							end loop;
						end if;
						if mode = "000" or mode = "001" then
							-- one register to Dn or An
							if cw(12) = '1' then
								v32 := x"0000" & fpcr;
							elsif cw(11) = '1' then
								v32 := fpsr;
							else
								v32 := fpiar;
							end if;
							wr_en <= '1'; wr_size <= "10"; wr_data <= v32;
							if mode = "001" then
								wr_idx <= 8 + to_integer(unsigned(reg));
							else
								wr_idx <= to_integer(unsigned(reg));
							end if;
							done_r <= '1';
							state <= ST_FINISH;
						else
							xa <= addr; xi <= 0; xn <= nbytes; xwr <= '1';
							state <= ST_XFER; ret_state <= ST_FINISH;
						end if;
					elsif cls = "110" or cls = "111" then
						-- FMOVEM data registers, 12 bytes each, FP0 at the lowest address
						li <= 0;
						mptr <= addr;
						state <= ST_MOVEM;
					else
						done_r <= '1'; state <= ST_FINISH;
					end if;

				-- one bus cycle a clock: a word, or a byte for an odd address or
				-- the last byte
				when ST_XFER =>
					if xwr = '0' and xi < 12 then
						if xbyte = '1' then
							if xa(0) = '1' then buf(xi) <= data_in(7 downto 0);
							else buf(xi) <= data_in(15 downto 8); end if;
						else
							buf(xi) <= data_in(15 downto 8);
							buf(xi + 1) <= data_in(7 downto 0);
						end if;
					end if;
					if xbyte = '1' then
						xa <= xa + 1;
						if xi + 1 >= xn then state <= ST_XFER_DONE; else xi <= xi + 1; end if;
					else
						xa <= xa + 2;
						if xi + 2 >= xn then state <= ST_XFER_DONE; else xi <= xi + 2; end if;
					end if;
				when ST_XFER_DONE =>
					xframe <= '0';
					state <= ret_state;
					if (ret_state = ST_ALU or ret_state = ST_UNIMP) and store = '0' then
						-- convert the memory or immediate source
						case fmt is
							when "000" => alu_src <= int_to_x(signed(buf_long(buf, 0)));
							when "001" => alu_src <= sgl_to_x(buf_long(buf, 0));
							when "100" => alu_src <= int_to_x(resize(signed(std_logic_vector'(buf(0) & buf(1))), 32));
							when "110" => alu_src <= int_to_x(resize(signed(buf(0)), 32));
							when "101" => alu_src <= dbl_to_x(buf_long(buf, 0) & buf_long(buf, 4));
							when others =>
								alu_src <= buf(0) & buf(1) & buf_long(buf, 4) & buf_long(buf, 8);
						end case;
					elsif ret_state = ST_FINISH then
						done_r <= '1';
					end if;

				when ST_ALU =>
					if uop = '1' then
						state <= ST_UNIMP;
					else
						alu_start <= '1';
						state <= ST_ALU_WAIT;
					end if;
				when ST_UNIMP =>
					-- keep what the FPSP needs and report the exception
					etemp <= alu_src;
					fptemp <= fpr(to_integer(unsigned(cw(9 downto 7))));
					cmd1b <= cw;
					unimp_pend <= '1';
					unimp_r <= '1';
					done_r <= '1';
					state <= ST_FINISH;
				when ST_ALU_WAIT =>
					if alu_done = '1' then
						e := alu_exc;
						-- EXC: BSUN SNAN OPERR OVFL UNFL DZ INEX2 INEX1
						fpsr(15 downto 8) <= '0' & e(5) & e(4) & e(3) & e(2) & e(1) & e(0) & '0';
						-- AEXC: IOP OVFL UNFL DZ INEX (68040 UM 9.2.3.4)
						fpsr(7) <= fpsr(7) or e(5) or e(4);
						fpsr(6) <= fpsr(6) or e(3);
						fpsr(5) <= fpsr(5) or (e(2) and e(0));
						fpsr(4) <= fpsr(4) or e(1);
						fpsr(3) <= fpsr(3) or e(0) or e(3);
						if set_cc = '1' then
							-- condition codes N Z I NAN of the result
							x := alu_res;
							fpsr(27) <= x(79);
							fpsr(26) <= '0'; fpsr(25) <= '0'; fpsr(24) <= '0';
							if x(78 downto 64) = "111111111111111" then
								if x(62 downto 0) = (62 downto 0 => '0') then fpsr(25) <= '1'; else fpsr(24) <= '1'; end if;
							elsif x(63 downto 0) = x"0000000000000000" then
								fpsr(26) <= '1';
							end if;
						end if;
						if wr_fp = '1' then
							fpr(to_integer(unsigned(cw(9 downto 7)))) <= alu_res;
						end if;
						if store = '1' then
							state <= ST_STORE;
						else
							done_r <= '1';
							state <= ST_FINISH;
						end if;
					end if;

				-- FMOVE FPn,<ea>: the converted result to Dn or memory
				when ST_STORE =>
					x := alu_res;
					case fmt is
						when "001" => v32 := x_to_sgl(x);
						when others => v32 := x(31 downto 0);
					end case;
					if fmt = "101" then
						v64 := x_to_dbl(x);
						for i in 0 to 7 loop
							buf(i) <= v64(63 - 8 * i downto 56 - 8 * i);
						end loop;
					elsif fmt = "100" then
						buf(0) <= v32(15 downto 8); buf(1) <= v32(7 downto 0);
					elsif fmt = "110" then
						buf(0) <= v32(7 downto 0);
					else
						for i in 0 to 3 loop
							buf(i) <= v32(31 - 8 * i downto 24 - 8 * i);
						end loop;
					end if;
					if mode = "000" then
						wr_en <= '1'; wr_idx <= to_integer(unsigned(reg)); wr_data <= v32;
						case fmt is
							when "110" => wr_size <= "00";
							when "100" => wr_size <= "01";
							when others => wr_size <= "10";
						end case;
						done_r <= '1';
						state <= ST_FINISH;
					else
						xa <= addr; xi <= 0; xn <= nbytes; xwr <= '1';
						state <= ST_XFER; ret_state <= ST_FINISH;
					end if;

				-- FMOVE(M) to the control registers, from buf in FPCR FPSR FPIAR order
				when ST_CTRL =>
					idx := 0;
					if cw(12) = '1' then
						fpcr <= buf(2) & buf(3);
						fpcr(3 downto 0) <= "0000";
						idx := 4;
					end if;
					if cw(11) = '1' then
						fpsr <= buf_long(buf, idx);
						idx := idx + 4;
					end if;
					if cw(10) = '1' then
						fpiar <= buf_long(buf, idx);
					end if;
					done_r <= '1';
					state <= ST_FINISH;

				-- FMOVEM data registers, one register a pass through the sequencer,
				-- in ascending order of register and address. In the control and
				-- postincrement modes FP0 is list bit 7; in the predecrement mode
				-- FP0 is bit 0, and ST_EA has put addr at the bottom of the block.
				when ST_MOVEM =>
					if li = 8 then
						done_r <= '1';
						state <= ST_FINISH;
					else
						if (cw(12) = '1' and list(7 - li) = '1') or (cw(12) = '0' and list(li) = '1') then
							x := fpr(li);
							buf(0) <= x(79 downto 72); buf(1) <= x(71 downto 64);
							buf(2) <= x"00"; buf(3) <= x"00";
							for i in 0 to 7 loop
								buf(4 + i) <= x(63 - 8 * i downto 56 - 8 * i);
							end loop;
							xwr <= cw(13);
							xa <= mptr; xi <= 0; xn <= 12;
							mptr <= mptr + 12;
							state <= ST_XFER; ret_state <= ST_MOVEM_W;
						else
							li <= li + 1;
						end if;
					end if;
				when ST_MOVEM_W =>
					if cw(13) = '0' then
						fpr(li) <= buf(0) & buf(1) & buf_long(buf, 4) & buf_long(buf, 8);
					end if;
					li <= li + 1;
					state <= ST_MOVEM;

				when ST_DBCC =>
					br_r <= '1';
					brt <= addr + unsigned(resize(signed(std_logic_vector'(buf(0) & buf(1))), 32));
					done_r <= '1';
					state <= ST_FINISH;

				when ST_RESTORE =>
					-- FRESTORE: a null frame resets the FPU; other frames are skipped
					if mode = "011" and buf(1) /= x"00" then
						-- (An)+ skips the rest of a longer frame
						wr_en <= '1'; wr_idx <= 8 + to_integer(unsigned(reg)); wr_size <= "10";
						wr_data <= std_logic_vector(unsigned(areg) + 4 + unsigned(buf(1)));
					end if;
					unimp_pend <= '0';
					if buf(0) = x"00" then
						fpr <= (others => FP_NAN);
						fpcr <= (others => '0');
						fpsr <= (others => '0');
						fpiar <= (others => '0');
						null_state <= '1';
					else
						null_state <= '0';
					end if;
					done_r <= '1';
					state <= ST_FINISH;

				when ST_FINISH =>
					state <= IDLE;
				end case;
			end if;
		end if;
	end process;
end architecture;
