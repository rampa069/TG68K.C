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
--   FScc, FDBcc, FTRAPcc
--   FSAVE (null or idle frame), FRESTORE
-- The operations the 68040 leaves to the M68040FPSP (the transcendental
-- functions, FINT, FINTRZ, FGETEXP, FGETMAN, FMOD, FREM, FSCALE, FSGL*) are
-- done as the 68040 does them (UM 9.6): the source operand is fetched and
-- converted, unimp is set with done, and the kernel takes the unimplemented
-- floating-point instruction exception (vector 11, format $2); the FSAVE
-- of the FPSP then gets the 26-word unimplemented instruction frame with
-- the command word, the source (ETEMP), the destination register (FPTEMP)
-- and their tags. FMOVECR is one of them (UM table 9-10): nothing to fetch,
-- the frame holds its command word for the FPSP's smovcr; with a nonzero
-- <ea> field the kernel takes Line-F (format $0) instead, which the FPSP
-- emulates FMOVECR from too (x_fline.sa). Packed
-- decimal is an unsupported data type, as on the 68040 (UM 9.6.2): a packed
-- source is read as it is (bits 95-64 to FPTEMP, 63-0 to ETEMP) and
-- unsupp is set with done, and the kernel takes vector 55 with a format $0
-- frame; FMOVE.P FPn,<ea> writes nothing, sets unsupp and post, and the
-- kernel takes vector 55 with a format $3 frame (the effective address).
-- The FSAVE of the FPSP then gets the 50-word busy frame, and an FRESTORE
-- of a busy frame that the FPSP has left with CU_SAVEPC = $FE and E1 and
-- E3 clear runs the command word on ETEMP and FPTEMP, as the 68040
-- completes the instruction (res_func of the FPSP). Immediate data is read
-- like a memory operand at the address the kernel gives.
--
-- Floating-point arithmetic exceptions (UM 9.7, testbed-9bf.16). The unit
-- computes the result the 68040 and the M68040FPSP give together, so it
-- traps only when an exception the instruction raises is enabled in the
-- FPCR; it then takes the vector the 68040 would take (OVFL and UNFL are
-- nonmaskable there, so they come before DZ and INEX) and leaves the state
-- the FPSP handlers read in a 50-word busy frame (fpsp.h offsets): for
-- FADD, FSUB, FMUL, FDIV, FSQRT, FSGLDIV and FSGLMUL with OVFL, UNFL or
-- INEX2 an E3 exception with CMDREG3B and the intermediate result in
-- WBTEMP (rounded for OVFL; before rounding, with guard, round and sticky,
-- for UNFL), otherwise E1 with CMDREG1B, the source in ETEMP and the
-- destination in FPTEMP (for FMOVE, FABS and FNEG with OVFL or UNFL the
-- intermediate result in both) and the nonmaskable exceptions in NMCEXC.
-- The destination register is not written for OPERR, OVFL, UNFL and DZ
-- (the FPSP writes OVFL and UNFL results). The exception is pending: the
-- next floating-point instruction other than FSAVE and FRESTORE takes it
-- as a pre-instruction exception (format $0, its own address). FMOVE to
-- memory or Dn takes it at once as a post-instruction exception (T set,
-- format $3 with the effective address, 0 for Dn). FSAVE stores and clears
-- the pending frame; FRESTORE of a busy frame with E1 or E3 set makes it
-- pending again, with the vector the 68040 derives from NMCEXC and the
-- FPSR (gen_except of the FPSP). BSUN enabled traps FScc, FDBcc, FTRAPcc
-- and FBcc before the predicate is used (vector 48), with an E1 busy frame
-- (Linux's skeleton clears E1 for it).
--
-- Copyright (c) 2026 Ramon Martinez. LGPL-3.0-or-later, as TG68K.C.
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K_FPU is
	generic (
		-- 1: as the MC68040, which leaves to the M68040FPSP what it does not
		-- do in hardware: OVFL and UNFL always trap, so do SNAN and OPERR of
		-- FMOVE to an integer, and denormalized and unnormalized operands take
		-- the unsupported data type exception (UM 9.6.2, 9.7). 0: the unit
		-- completes all of it and traps only for exceptions enabled in the FPCR
		-- (for software without the FPSP)
		FPSP : integer := 1
	);
	port (
		clk       : in  std_logic;
		reset     : in  std_logic;
		clkena    : in  std_logic;
		-- instruction
		start     : in  std_logic;
		abort     : in  std_logic := '0';			-- access error: drop the instruction
		opcode    : in  std_logic_vector(15 downto 0);
		cmd       : in  std_logic_vector(15 downto 0);
		ea        : in  std_logic_vector(31 downto 0);	-- modes 5, 6, 7: the operand address
																-- (for #imm, where the data starts)
		iaddr     : in  std_logic_vector(31 downto 0);	-- address of the instruction (FPIAR)
		done      : out std_logic;
		unimp     : out std_logic;					-- with done: unimplemented, take vector 11
		unsupp    : out std_logic;					-- with done: unsupported data type, vector 55
		upost     : out std_logic;					-- with unsupp: post-instruction (format $3)
		ea_out    : out std_logic_vector(31 downto 0);	-- the operand address, for that frame
		ftrap     : out std_logic;					-- with done: FTRAPcc traps
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
		pred_true : out std_logic;
		pred_bsun : in  std_logic := '0';				-- FBcc evaluated pred: set BSUN on a NaN
		-- arithmetic exceptions: xexc with done takes vector 48 + xvec (0 BSUN,
		-- 1 INEX, 2 DZ, 3 UNFL, 4 OPERR, 5 OVFL, 6 SNAN), post-instruction with
		-- a format $3 frame when xpost is set; xpend says one is pending (FBcc
		-- takes it), fpcc_nan and fp_bsun_en decide a BSUN trap of FBcc, which
		-- set_bsun records in the FPSR
		xexc      : out std_logic;
		xvec      : out std_logic_vector(2 downto 0);
		xpost     : out std_logic;
		xhere_o   : out std_logic;					-- with xexc and xpost: the PC is this instruction's
		xpend_o   : out std_logic;
		xpend_vec : out std_logic_vector(2 downto 0);
		fpcc_nan  : out std_logic;
		fp_bsun_en : out std_logic;
		set_bsun  : in  std_logic := '0'
	);
end entity;

architecture rtl of TG68K_FPU is
	type fpregs_t is array (0 to 7) of std_logic_vector(79 downto 0);
	type bytes_t is array (0 to 11) of std_logic_vector(7 downto 0);
	type frame_t is array (0 to 99) of std_logic_vector(7 downto 0);
	constant FP_NAN : std_logic_vector(79 downto 0) := x"7FFF" & x"FFFFFFFFFFFFFFFF";

	signal fpr : fpregs_t := (others => FP_NAN);
	signal fpcr : std_logic_vector(15 downto 0) := (others => '0');
	signal fpsr : std_logic_vector(31 downto 0) := (others => '0');
	signal fpiar : std_logic_vector(31 downto 0) := (others => '0');
	signal null_state : std_logic := '1';

	type state_t is (IDLE, ST_REG, ST_EA, ST_SRC, ST_XFER, ST_XFER_DONE, ST_ALU, ST_ALU_WAIT,
					 ST_STORE, ST_CTRL, ST_MOVEM, ST_MOVEM_W, ST_RESTORE, ST_RESTORE_B, ST_DBCC, ST_UNIMP,
					 ST_UNSUPP, ST_LIST, ST_FINISH);
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
	signal xi, xn : integer range 0 to 100;
	signal xrframe : std_logic := '0';		-- FRESTORE: reading the fields of a busy frame
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
	signal alu_early : std_logic;
	-- the pending unimplemented instruction, for the FSAVE frame
	signal unimp_pend : std_logic := '0';
	signal uop : std_logic;
	signal etemp, fptemp : std_logic_vector(79 downto 0);
	signal cmd1b : std_logic_vector(15 downto 0);
	-- the unsupported data type, for the busy frame
	signal busy_pend : std_logic := '0';
	signal unsupp_r, upost_r : std_logic := '0';
	signal pk : std_logic;				-- the source is packed decimal
	signal fe1, ft : std_logic;			-- E1 and T of the frame
	signal stag, dtag : std_logic_vector(7 downto 0);
	-- what an FRESTORE of a busy frame brings back
	signal cusave : std_logic_vector(7 downto 0);
	signal re1, re3 : std_logic;
	signal ufr : frame_t;
	signal br_r, ftrap_r : std_logic := '0';
	-- the pending arithmetic exception and its busy frame (also one FRESTORE
	-- brought back)
	signal xf : frame_t;
	signal xpend : std_logic := '0';
	signal xraw : std_logic := '0';		-- FSAVE: the data comes from xf
	-- the 26-word frame (E1 exceptions, as on the 68040): its fields are
	-- xf(52..99), the end of the busy frame; xro reads one into there
	signal xsmall : std_logic := '0';
	signal xro : integer range 0 to 48 := 0;
	signal ru : std_logic := '0';			-- the U flag of the frame FRESTORE reads
	signal xvec_r : std_logic_vector(2 downto 0);
	signal xnow, xpost_r, xst : std_logic := '0';
	signal ires_s : std_logic;
	signal xhere : std_logic := '0';		-- a pending E3 reported as a post-instruction
											-- exception by the FMOVE out of its register
	signal xe3 : std_logic := '0';			-- the pending exception is an E3 one
	signal rfun : std_logic := '0';			-- the operation comes from FRESTORE (res_func)
	signal ires_e, rres_e : signed(17 downto 0);
	signal ires_m, rres_m : unsigned(67 downto 0);
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
			-- an infinity or a NaN: the fraction left-justified, J clear
			-- (the integer bit is a don't care there, PRM 1.6.5; a 68881/
			-- 68882/68040 clears it)
			return s(31) & "111111111111111" & '0' & s(22 downto 0) & x"0000000000";
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
			return d(63) & "111111111111111" & '0' & d(51 downto 0) & "00000000000";
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

	-- operand tags of the state frames (UM 9.8, STAG and DTAG): norm $00,
	-- zero $20, infinity $40, NaN $60, an extended denormal or unnormal $80
	-- ($A0, a single or double denormal, is set where the format is known)
	function tag_of(x : std_logic_vector(79 downto 0)) return std_logic_vector is
	begin
		if x(78 downto 64) = "111111111111111" then
			if x(62 downto 0) = (62 downto 0 => '0') then return x"40"; end if;
			return x"60";
		elsif x(63 downto 0) = x"0000000000000000" then
			return x"20";
		elsif x(63) = '0' then
			return x"80";
		end if;
		return x"00";
	end function;

	-- an operand the 68040 does not take in hardware: denormalized or
	-- unnormalized, not zero (an exponent of 0 with J set is the normalized
	-- 2^-16383, testbed-9bf.36)
	function unsup_of(x : std_logic_vector(79 downto 0)) return boolean is
	begin
		return x(78 downto 64) /= "111111111111111" and x(63) = '0' and x(62 downto 0) /= (62 downto 0 => '0');
	end function;

	-- the arithmetic unit operation of a command word, bit 4 set when the
	-- unit has it (FSQRT also as $05, its CMDREG1B form, UM 9.8)
	function op_of(opm : std_logic_vector(6 downto 0)) return std_logic_vector is
	begin
		case opm is
			when "0000000" | "1000000" | "1000100" => return "10000";	-- FMOVE
			when "0011000" | "1011000" | "1011100" => return "10001";	-- FABS
			when "0011010" | "1011010" | "1011110" => return "10010";	-- FNEG
			when "0000100" | "0000101" | "1000001" | "1000101" => return "10011";	-- FSQRT
			when "0100010" | "1100010" | "1100110" => return "10100";	-- FADD
			when "0101000" | "1101000" | "1101100" => return "10101";	-- FSUB
			when "0100011" | "1100011" | "1100111" => return "10110";	-- FMUL
			when "0100000" | "1100000" | "1100100" => return "10111";	-- FDIV
			when "0111000" => return "11000";							-- FCMP
			when "0111010" => return "11001";							-- FTST
			when "0100100" => return "11011";							-- FSGLDIV
			when "0100111" => return "11100";							-- FSGLMUL
			when others => return "00000";
		end case;
	end function;

	-- the vector of the highest priority exception in m (snan operr ovfl unfl
	-- dz inex), INEX when none
	function xvec_of(m : std_logic_vector(5 downto 0)) return std_logic_vector is
	begin
		if m(5) = '1' then return "110";
		elsif m(4) = '1' then return "100";
		elsif m(3) = '1' then return "101";
		elsif m(2) = '1' then return "011";
		elsif m(1) = '1' then return "010";
		end if;
		return "001";
	end function;

	-- CMDREG3B from a CMDREG1B command word (UM figure 9-11, as gen_except
	-- of the FPSP builds it): the destination register, bit 6, then bit 2,
	-- bits 5-3 and bits 1-0 of the operation
	function cmd3b_of(c : std_logic_vector(15 downto 0)) return std_logic_vector is
	begin
		return "000000" & c(9 downto 7) & c(6) & c(2) & c(5 downto 3) & c(1 downto 0);
	end function;

	-- an extended value from the unit's intermediate result: sign, the low
	-- 15 bits of the biased exponent (UNFL leaves it negative, which the FPSP
	-- sign-extends from bit 14) and the 64-bit mantissa
	function ires_x(sg : std_logic; e : signed(17 downto 0); m : unsigned(67 downto 0)) return std_logic_vector is
		variable b : signed(17 downto 0);
	begin
		b := e + 16383;
		return sg & std_logic_vector(b(14 downto 0)) & std_logic_vector(m(66 downto 3));
	end function;

	-- an operand the FPSP hands back for res_func: a 15-bit exponent with its
	-- bit 15 apart (ETE15 in STAG, FPTE15 in DTAG, set by mk_norm for an
	-- exponent up to $3FFF), so a normalized denormal, whose biased exponent
	-- is negative, comes as $4000-$7FFF with that bit set: e - $8000. It goes
	-- to the arithmetic unit as the extended denormal of the same value.
	function frame_x(x : std_logic_vector(79 downto 0); e15 : std_logic) return std_logic_vector is
		variable n : integer range 0 to 16384;
		variable m : unsigned(63 downto 0);
	begin
		if e15 = '1' and x(78) = '1' then
			n := 32768 - to_integer(unsigned(x(78 downto 64)));		-- the shift, -e
			if n > 63 then
				m := (others => '0');
			else
				m := shift_right(unsigned(x(63 downto 0)), n);
			end if;
			return x(79) & "000000000000000" & std_logic_vector(m);
		end if;
		return x;
	end function;

	-- the busy frame of a BSUN exception: E1, the instruction address
	function bsun_frame(ia : std_logic_vector(31 downto 0)) return frame_t is
		variable f : frame_t;
	begin
		f := (others => x"00");
		f(0) := x"41"; f(1) := x"60";
		f(40) := ia(31 downto 24); f(41) := ia(23 downto 16);
		f(42) := ia(15 downto 8); f(43) := ia(7 downto 0);
		f(72) := x"04";
		return f;
	end function;

	function buf_long(b : bytes_t; i : integer) return std_logic_vector is
	begin
		return b(i) & b(i + 1) & b(i + 2) & b(i + 3);
	end function;
begin
	-- done also in the cycle the arithmetic unit finishes a register result,
	-- one cycle before ST_FINISH
	done <= done_r OR alu_early;
	unimp <= unimp_r;
	unsupp <= unsupp_r;
	upost <= upost_r;
	ea_out <= (others => '0') when xpost_r = '1' and mode = "000" else std_logic_vector(addr);
	xexc <= xnow;
	xvec <= xvec_r;
	xpost <= xpost_r;
	xpend_o <= xpend;
	xhere_o <= xhere;
	xpend_vec <= xvec_r;
	fpcc_nan <= fpsr(24);
	fp_bsun_en <= fpcr(15);

	-- the 26-word unimplemented instruction frame and the 50-word busy
	-- frame (68040 UM figure 9-10). The FPSP addresses the fields from the
	-- end of the frame (fpsp.h), so the busy frame has each 48 bytes further
	-- on: version $41, size $30 or $60, STAG, CMDREG1B, DTAG, the E1 and T
	-- bytes, FPTEMP and ETEMP; the rest is zero (CU_SAVEPC among them).
	process (etemp, fptemp, cmd1b, stag, dtag, fe1, ft, busy_pend, fpiar)
		variable f : frame_t;
		variable o : integer range 0 to 48;
	begin
		f := (others => x"00");
		f(0) := x"41";
		if busy_pend = '1' then
			f(1) := x"60"; o := 48;
			f(40) := fpiar(31 downto 24); f(41) := fpiar(23 downto 16);	-- FPIARCU
			f(42) := fpiar(15 downto 8); f(43) := fpiar(7 downto 0);
		else
			f(1) := x"30"; o := 0;
		end if;
		f(o + 12) := stag;						-- STAG
		f(o + 16) := cmd1b(15 downto 8); f(o + 17) := cmd1b(7 downto 0);	-- CMDREG1B
		f(o + 20) := dtag;						-- DTAG
		f(o + 24) := "00000" & fe1 & "00";		-- E1
		f(o + 25) := "001" & ft & "0000";		-- U (an unimplemented or unsupported frame), T
		f(o + 28) := fptemp(79 downto 72); f(o + 29) := fptemp(71 downto 64);
		for i in 0 to 7 loop
			f(o + 32 + i) := fptemp(63 - 8 * i downto 56 - 8 * i);
		end loop;
		f(o + 40) := etemp(79 downto 72); f(o + 41) := etemp(71 downto 64);
		for i in 0 to 7 loop
			f(o + 44 + i) := etemp(63 - 8 * i downto 56 - 8 * i);
		end loop;
		ufr <= f;
	end process;
	alu_early <= '1' WHEN state = ST_ALU_WAIT AND alu_done = '1' AND store = '0' ELSE '0';
	br_take <= br_r;
	ftrap <= ftrap_r;
	br_target <= std_logic_vector(brt);

	alu : entity work.TG68K_FPU_ALU
		port map (clk => clk, reset => reset, ena => clkena, start => alu_start, op => alu_op, rmode => alu_rm,
				  rprec => alu_rp, to_mem => alu_tomem, dst => alu_dst, src => alu_src,
				  busy => alu_busy, done => alu_done, result => alu_res, exc => alu_exc,
				  ires_s => ires_s, ires_e => ires_e, ires_m => ires_m, rres_e => rres_e, rres_m => rres_m);

	pred_true <= pred_eval(pred, fpsr(27), fpsr(26), fpsr(24));

	-- the bus cycle of the sequencer
	bus_act <= '1' when state = ST_XFER else '0';
	bus_addr <= std_logic_vector(xa(31 downto 1)) & '0';
	bus_wr <= xwr;
	xbyte <= '1' when xa(0) = '1' or xn - xi = 1 else '0';
	bus_uds_n <= '1' when xbyte = '1' and xa(0) = '1' else '0';
	bus_lds_n <= '1' when xbyte = '1' and xa(0) = '0' else '0';
	process (xframe, xraw, xsmall, xbyte, xi, ufr, buf, xf)
	begin
		if xframe = '1' and xraw = '1' and xsmall = '1' then
			if xi = 0 then
				bus_wdata <= x"4130";
			elsif xi < 4 or xi > 51 then
				bus_wdata <= x"0000";
			else
				bus_wdata <= xf(xi + 48) & xf(xi + 49);
			end if;
		elsif xframe = '1' and xraw = '1' and xi < 99 then
			bus_wdata <= xf(xi) & xf(xi + 1);
		elsif xframe = '1' and xi < 99 then
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
		variable isop : boolean;
		variable movecr : boolean;
		variable hit : std_logic;
		variable xm : std_logic_vector(5 downto 0);
		variable f : frame_t;
		variable c1 : std_logic_vector(15 downto 0);
		variable ix : std_logic_vector(79 downto 0);
		variable e3 : boolean;
		variable lneg : boolean;
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
				busy_pend <= '0';
				xframe <= '0';
				xrframe <= '0';
				xpend <= '0';
				xraw <= '0';
				xnow <= '0';
			elsif clkena = '1' then
				done_r <= '0';
				unimp_r <= '0';
				unsupp_r <= '0';
				xnow <= '0';
				alu_start <= '0';
				wr_en <= '0';
				if abort = '1' then
					-- an access error on one of its bus cycles: the kernel restores
					-- the integer registers and restarts the instruction
					state <= ST_FINISH;
					xframe <= '0';
					xrframe <= '0';
				else
				if (pred_bsun = '1' and pred(4) = '1' and fpsr(24) = '1') or set_bsun = '1' then
					fpsr(15) <= '1';		-- BSUN, and AEXC IOP
					fpsr(7) <= '1';
				end if;
				if set_bsun = '1' then
					-- FBcc takes BSUN (the kernel traps): the exceptional state
					xf <= bsun_frame(iaddr);
					xpend <= '1';
					xsmall <= '1';
					xe3 <= '0';
					xvec_r <= "000";
				end if;
				case state is
				when IDLE =>
					br_r <= '0';
					ftrap_r <= '0';
					if start = '1' and xpend = '1' and opcode(8 downto 7) /= "10" then
						-- a pending exception: this instruction takes it first, a
						-- pre-instruction exception (FSAVE and FRESTORE do not). An
						-- FMOVE out of the register an E3 exception has to write
						-- needs that result first, and the 68040 reports it as a
						-- post-instruction exception, T set and no effective
						-- address, with this instruction's PC (UM 9.7.4)
						xpost_r <= '0';
						xhere <= '0';
						if FPSP = 1 and xe3 = '1' and opcode(8 downto 6) = "000" and cmd(15 downto 13) = "011" and
						   cmd(9 downto 7) = xf(52)(1 downto 0) & xf(53)(7) then
							xpost_r <= '1';
							xhere <= '1';
							xf(73)(4) <= '1';
							mode <= "000";		-- the format $3 frame gets no address
						end if;
						xnow <= '1';
						done_r <= '1';
						state <= ST_FINISH;
					elsif start = '1' then
						xpost_r <= '0';
						xhere <= '0';
						xst <= '0';
						rfun <= '0';
						opc <= opcode;
						cw <= cmd;
						mode <= opcode(5 downto 3);
						reg <= opcode(2 downto 0);
						cls <= cmd(15 downto 13);
						fmt <= cmd(12 downto 10);
						wr_fp <= '0';
						set_cc <= '0';
						store <= '0';
						pk <= '0';
						upost_r <= '0';
						state <= ST_REG;
						if opcode(8 downto 6) = "000" and cmd(15 downto 13) = "000" then
							state <= ST_SRC;		-- FPm,FPn: no effective address
						end if;
					end if;

				-- An or Dn of the effective address is on rd_data now
				when ST_REG =>
					areg <= rd_data;
					-- operand size in memory
					if opc(8 downto 6) = "100" and xpend = '1' and xsmall = '1' then
						nb := 52;								-- FSAVE, E1 exception frame
					elsif opc(8 downto 6) = "100" and (busy_pend = '1' or xpend = '1') then
						nb := 100;								-- FSAVE, busy frame
					elsif opc(8 downto 6) = "100" and unimp_pend = '1' then
						nb := 52;								-- FSAVE, unimplemented frame
					elsif opc(8 downto 6) = "100" or opc(8 downto 6) = "101" then
						nb := 4;								-- FSAVE, FRESTORE header
					elsif opc(8 downto 6) = "001" then
						nb := 1;								-- FScc byte (FDBcc, FTRAPcc: none)
					elsif cls = "100" or cls = "101" then
						nb := 4 * popcount3(cw(12 downto 10));	-- control registers
					elsif cls = "110" or cls = "111" then
						-- static list (mode bit 11 clear), or one in Dn (ST_LIST)
						list <= cw(7 downto 0);
						nb := 12 * popcount8(cw(7 downto 0));
					elsif cls = "011" and fmt = "111" then
						nb := 12;								-- FMOVE.P, dynamic k-factor
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
						if cw(4) = '1' and fpsr(24) = '1' and fpcr(15) = '1' then
							-- BSUN enabled: the pre-instruction exception, before the
							-- predicate is used (UM 9.7.1)
							xvec_r <= "000";
							xf <= bsun_frame(iaddr);
							xpend <= '1';
							xsmall <= '1';
							xe3 <= '0';
							xnow <= '1';
							done_r <= '1'; state <= ST_FINISH;
						elsif mode = "111" and reg(2 downto 1) /= "00" then
							-- FTRAPcc: the kernel takes vector 7 when the predicate is true
							ftrap_r <= pred_eval(cw(5 downto 0), fpsr(27), fpsr(26), fpsr(24));
							done_r <= '1'; state <= ST_FINISH;
						elsif mode = "001" then
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
						-- the pending frame is cleared once stored (ST_XFER_DONE)
						if xpend = '1' then
							xn <= 100;
							if xsmall = '1' then xn <= 52; end if;
							xframe <= '1';
							xraw <= '1';
						elsif busy_pend = '1' then
							xn <= 100;
							xframe <= '1';
						elsif unimp_pend = '1' then
							xn <= 52;
							xframe <= '1';
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
							when "0100100" => alu_op <= x"B";							-- FSGLDIV
							when "0100111" => alu_op <= x"C";							-- FSGLMUL
							when others => ok := false;
						end case;
						-- an operation the 68040 leaves to the FPSP: the source is
						-- fetched and converted all the same (ST_UNIMP)
						movecr := cls = "010" and fmt = "111";
						if ok and not movecr then uop <= '0'; else uop <= '1'; end if;
						isop := ok and not movecr;
						ok := true;
						if cls = "010" and fmt = "011" then
							pk <= '1';			-- packed decimal: an unsupported data type
						end if;
						if not ok then
							done_r <= '1'; state <= ST_FINISH;
						else
							-- precision: the FS and FD forms, else FPCR PREC, where the
							-- undefined 11 rounds to double as the M68040FPSP does it
							-- (round.S ext_grs, add_to_l; util.S denorm)
							if opm(6) = '1' then
								if opm(2) = '1' then alu_rp <= "10"; else alu_rp <= "01"; end if;
							else
								alu_rp <= fpcr(7) & (fpcr(6) and not fpcr(7));
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
							if movecr then
								-- FMOVECR: no operand; ETEMP 0
								alu_src <= (others => '0');
								state <= ST_UNIMP;
							elsif cls = "000" then
								alu_src <= fpr(to_integer(unsigned(cw(12 downto 10))));
								if isop and FPSP = 0 then
									alu_start <= '1';		-- the unit starts now (no ST_ALU)
									state <= ST_ALU_WAIT;
								else
									state <= ST_ALU;
								end if;
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
						-- FMOVE FPn,<ea> (through ST_ALU: not an unimplemented one,
						-- whatever the instruction before was)
						uop <= '0';
						fpn := to_integer(unsigned(cw(9 downto 7)));
						alu_src <= fpr(fpn);
						alu_dst <= fpr(fpn);
						alu_rm <= fpcr(5 downto 4);
						alu_tomem <= '1';
						store <= '1';
						fpiar <= iaddr;
						if FPSP = 1 and unsup_of(fpr(fpn)) and fmt /= "011" and fmt /= "111" then
							-- FMOVE out of a denormalized or unnormalized register: the
							-- post-instruction unsupported data type exception, nothing
							-- written (ETEMP and FPTEMP the register, as WinUAE has it)
							etemp <= fpr(fpn);
							stag <= tag_of(fpr(fpn));
							fptemp <= fpr(fpn);
							dtag <= tag_of(fpr(fpn));
							cmd1b <= cw;
							fe1 <= '0'; ft <= '1';
							busy_pend <= '1'; unimp_pend <= '0';
							unsupp_r <= '1'; upost_r <= '1';
							done_r <= '1'; state <= ST_FINISH;
						else
						case fmt is
							when "000" => alu_op <= x"A"; alu_rp <= "10"; state <= ST_ALU;
							when "100" => alu_op <= x"A"; alu_rp <= "01"; state <= ST_ALU;
							when "110" => alu_op <= x"A"; alu_rp <= "00"; state <= ST_ALU;
							when "001" => alu_op <= x"0"; alu_rp <= "01"; state <= ST_ALU;
							when "101" => alu_op <= x"0"; alu_rp <= "10"; state <= ST_ALU;
							when "011" | "111" =>
								-- packed decimal: the post-instruction unsupported data
								-- type exception, the FPSP converts and stores it
								etemp <= fpr(fpn);
								stag <= tag_of(fpr(fpn));
								dtag <= x"00";
								fptemp <= (others => '0');
								cmd1b <= cw;
								fe1 <= '1'; ft <= '1';
								busy_pend <= '1'; unimp_pend <= '0';
								unsupp_r <= '1'; upost_r <= '1';
								done_r <= '1'; state <= ST_FINISH;
							when "010" =>
								-- extended: through the unit as a move, which keeps the
								-- value (a denormal as it is, with UNFL, the FPSP's result
								-- for it) and quiets an SNaN with SNAN set (UM 9.7.2.1)
								alu_op <= x"0"; alu_rp <= "00"; state <= ST_ALU;
							when others =>
								done_r <= '1'; state <= ST_FINISH;
						end case;
						end if;
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
					if xrframe = '1' then
						-- FRESTORE of a busy frame: all of it (an exceptional state
						-- comes back as it was saved), and the fields it needs
						xf(xi + xro) <= data_in(15 downto 8);
						xf(xi + xro + 1) <= data_in(7 downto 0);
						case xi + xro is
							when 8 => cusave <= data_in(15 downto 8);
							when 64 => cmd1b <= data_in;
							when 72 => re1 <= data_in(10); re3 <= data_in(9); ru <= data_in(5);
							when 76 => fptemp(79 downto 64) <= data_in;
							when 80 => fptemp(63 downto 48) <= data_in;
							when 82 => fptemp(47 downto 32) <= data_in;
							when 84 => fptemp(31 downto 16) <= data_in;
							when 86 => fptemp(15 downto 0) <= data_in;
							when 88 => etemp(79 downto 64) <= data_in;
							when 92 => etemp(63 downto 48) <= data_in;
							when 94 => etemp(47 downto 32) <= data_in;
							when 96 => etemp(31 downto 16) <= data_in;
							when 98 => etemp(15 downto 0) <= data_in;
							when others => null;
						end case;
					elsif xwr = '0' and xi < 12 then
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
					xrframe <= '0';
					if xframe = '1' then
						busy_pend <= '0';
						unimp_pend <= '0';
						xpend <= '0';
						xraw <= '0';
					end if;
					state <= ret_state;
					if ret_state = ST_ALU and store = '0' and uop = '0' and pk = '0' and FPSP = 0 then
						alu_start <= '1';			-- with the converted source below
						state <= ST_ALU_WAIT;
					end if;
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
						xnow <= xst;
					end if;

				when ST_ALU =>
					isop := alu_op = x"4" or alu_op = x"5" or alu_op = x"6" or alu_op = x"7" or
					        alu_op = x"8" or alu_op = x"B" or alu_op = x"C";		-- dyadic
					if uop = '1' then
						state <= ST_UNIMP;
					elsif pk = '1' then
						state <= ST_UNSUPP;
					elsif FPSP = 1 and rfun = '0' and
					      ((unsup_of(alu_src) and (cls = "000" or fmt = "001" or fmt = "101" or fmt = "010")) or
					       (isop and unsup_of(alu_dst))) then
						-- (an integer source is converted unnormalized on purpose)
						-- a denormalized or unnormalized operand: the pre-instruction
						-- unsupported data type exception (UM 9.6.2), the operands as
						-- they are in ETEMP and FPTEMP (a single or double denormal in
						-- the form of figure 9-9, tag $A0)
						etemp <= alu_src;
						stag <= tag_of(alu_src);
						if unsup_of(alu_src) and cls = "010" and (fmt = "001" or fmt = "101") then
							stag <= x"A0";
						end if;
						if isop then
							fptemp <= alu_dst;
							dtag <= tag_of(alu_dst);
						else
							fptemp <= (others => '0');
							dtag <= x"00";
						end if;
						if cw(6 downto 0) = "0000100" then
							cmd1b <= cw(15 downto 7) & "0000101";
						else
							cmd1b <= cw;
						end if;
						fe1 <= '0'; ft <= '0';
						busy_pend <= '1'; unimp_pend <= '0';
						unsupp_r <= '1';
						done_r <= '1';
						state <= ST_FINISH;
					else
						alu_start <= '1';
						state <= ST_ALU_WAIT;
					end if;
				when ST_UNIMP =>
					-- keep what the FPSP needs and report the exception
					x := fpr(to_integer(unsigned(cw(9 downto 7))));
					dtag <= tag_of(x);
					cmd1b <= cw;
					ft <= '0';
					if pk = '1' then
						-- a packed source: E1 set, bits 95-64 in FPTEMP, 63-0 in ETEMP
						etemp <= x"0000" & buf_long(buf, 4) & buf_long(buf, 8);
						fptemp <= x"000000000000" & buf_long(buf, 0);
						stag <= x"00";
						fe1 <= '1';
					else
						etemp <= alu_src;
						fptemp <= x;
						stag <= tag_of(alu_src);
						if unsup_of(alu_src) and cls = "010" and (fmt = "001" or fmt = "101") then
							stag <= x"A0";			-- a single or double denormal
						end if;
						fe1 <= '0';
					end if;
					unimp_pend <= '1';
					busy_pend <= '0';
					unimp_r <= '1';
					done_r <= '1';
					state <= ST_FINISH;
				when ST_UNSUPP =>
					-- packed decimal source of an operation the unit has: the
					-- pre-instruction unsupported data type exception (UM 9.6.2,
					-- table 9-16); FSQRT goes in CMDREG1B as $05 (UM 9.8)
					x := fpr(to_integer(unsigned(cw(9 downto 7))));
					dtag <= tag_of(x);
					stag <= x"00";
					etemp <= x"0000" & buf_long(buf, 4) & buf_long(buf, 8);
					fptemp <= x"000000000000" & buf_long(buf, 0);
					if cw(6 downto 0) = "0000100" then
						cmd1b <= cw(15 downto 7) & "0000101";
					else
						cmd1b <= cw;
					end if;
					fe1 <= '1'; ft <= '0';
					busy_pend <= '1'; unimp_pend <= '0';
					unsupp_r <= '1';
					done_r <= '1';
					state <= ST_FINISH;
				when ST_ALU_WAIT =>
					if alu_done = '1' then
						e := alu_exc;
						-- FMOVE to an integer of the largest negative integer: an
						-- operand error on the 68040 (the "erroneous MC68040
						-- condition" of UM 9.7.3.2), which the FPSP corrects
						lneg := false;
						if FPSP = 1 and store = '1' and alu_op = x"A" and alu_src(79) = '1' and e(5) = '0' and e(4) = '0' then
							case alu_rp is
								when "00" => lneg := alu_res(7 downto 0) = x"80";
								when "01" => lneg := alu_res(15 downto 0) = x"8000";
								when others => lneg := alu_res(31 downto 0) = x"80000000";
							end case;
						end if;
						-- EXC: BSUN SNAN OPERR OVFL UNFL DZ INEX2 INEX1
						fpsr(15 downto 8) <= '0' & e(5) & e(4) & e(3) & e(2) & e(1) & e(0) & '0';
						-- AEXC: IOP OVFL UNFL DZ INEX (68040 UM 9.2.3.4); the 68040
						-- leaves AINEX clear on an overflow (x_ovfl of the FPSP sets it)
						fpsr(7) <= fpsr(7) or e(5) or e(4);
						fpsr(6) <= fpsr(6) or e(3);
						fpsr(5) <= fpsr(5) or (e(2) and e(0));
						fpsr(4) <= fpsr(4) or e(1);
						if FPSP = 0 or e(3) = '0' then
							fpsr(3) <= fpsr(3) or e(0) or e(3);
						end if;
						-- it traps as an operand error, with no bit in the FPSR (the
						-- FPSP sets OPERR itself for a true one, x_operr)
						if lneg then
							e(4) := '1';
						end if;
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
						-- an enabled exception (testbed-9bf.16): the busy frame, and
						-- the destination register kept for OPERR, OVFL, UNFL and DZ;
						-- FMOVE out writes its destination and traps at once
						hit := (e(5) and fpcr(14)) or (e(4) and fpcr(13)) or (e(3) and fpcr(12)) or
						       (e(2) and fpcr(11)) or (e(1) and fpcr(10)) or (e(0) and fpcr(9));
						if FPSP = 1 then
							-- the nonmaskable ones: OVFL, UNFL, and SNAN and OPERR of
							-- FMOVE to an integer
							hit := hit or e(3) or e(2);
							if store = '1' and alu_op = x"A" then
								hit := hit or e(5) or e(4);
							end if;
						end if;
						if wr_fp = '1' and (hit = '0' or (e(4) or e(3) or e(2) or e(1)) = '0') then
							fpr(to_integer(unsigned(cw(9 downto 7)))) <= alu_res;
						end if;
						if hit = '1' then
							-- the vector the 68040 takes: OVFL and UNFL always, SNAN and
							-- OPERR always for FMOVE out (UM 9.7.2.2, 9.7.3.2)
							xm := (e(5) and (fpcr(14) or store)) & (e(4) and (fpcr(13) or store)) & e(3) & e(2) &
							      (e(1) and fpcr(10)) & (e(0) and fpcr(9));
							xvec_r <= xvec_of(xm);
							c1 := cw;
							if cw(6 downto 0) = "0000100" then
								c1(6 downto 0) := "0000101";		-- FSQRT (UM 9.8)
							end if;
							e3 := store = '0' and e(5) = '0' and e(4) = '0' and e(1) = '0' and
							      (alu_op = x"3" or alu_op = x"4" or alu_op = x"5" or alu_op = x"6" or
							       alu_op = x"7" or alu_op = x"B" or alu_op = x"C");
							f := (others => x"00");
							f(0) := x"41"; f(1) := x"60";
							f(40) := fpiar(31 downto 24); f(41) := fpiar(23 downto 16);		-- FPIARCU
							f(42) := fpiar(15 downto 8); f(43) := fpiar(7 downto 0);
							f(64) := c1(15 downto 8); f(65) := c1(7 downto 0);				-- CMDREG1B
							-- ETEMP and FPTEMP: the source (quieted for FMOVE out, as
							-- WinUAE has it) and the destination of a dyadic operation
							ix := alu_src;
							if store = '1' and tag_of(alu_src) = x"60" then
								ix(62) := '1';
							end if;
							f(60) := tag_of(alu_src);
							f(88) := ix(79 downto 72); f(89) := ix(71 downto 64);
							for i in 0 to 7 loop
								f(92 + i) := ix(63 - 8 * i downto 56 - 8 * i);
							end loop;
							if store = '0' and (alu_op = x"4" or alu_op = x"5" or alu_op = x"6" or alu_op = x"7" or
							                    alu_op = x"8" or alu_op = x"B" or alu_op = x"C") then
								ix := alu_dst;
								f(68) := tag_of(alu_dst);
								f(76) := ix(79 downto 72); f(77) := ix(71 downto 64);
								for i in 0 to 7 loop
									f(80 + i) := ix(63 - 8 * i downto 56 - 8 * i);
								end loop;
							end if;
							-- the intermediate result: before rounding for UNFL,
							-- rounded to the precision for OVFL and INEX2
							if e(2) = '1' then
								ix := ires_x(ires_s, ires_e, ires_m);
							else
								ix := ires_x(ires_s, rres_e, rres_m);
							end if;
							if e3 then
								f(72) := x"02";											-- E3
								v32 := x"0000" & cmd3b_of(c1);
								f(52) := v32(15 downto 8); f(53) := v32(7 downto 0);	-- CMDREG3B
								f(24) := ix(79 downto 72); f(25) := ix(71 downto 64);	-- WBTEMP
								for i in 0 to 7 loop
									f(28 + i) := ix(63 - 8 * i downto 56 - 8 * i);
								end loop;
								-- guard and round with STAG, sticky; WBTE15 for UNFL
								f(60)(1) := ires_m(2); f(60)(0) := ires_m(1);
								f(61)(7) := ires_m(0);
								if e(2) = '1' then
									f(69) := x"10";
								end if;
								xsmall <= '0';
								xe3 <= '1';
							else
								f(72) := x"04";											-- E1
								f(57) := "0000" & e(5) & e(4) & e(3) & e(2);			-- NMCEXC
								-- GRS 1, and for SNAN 7 with WBTE15, also for UNFL of
								-- FMOVE out (WinUAE's frames, from the hardware)
								f(61)(7) := '1';
								if e(5) = '1' then
									f(60)(1) := '1'; f(60)(0) := '1';
									f(69) := x"10";
								elsif store = '1' and e(2) = '1' then
									f(69) := x"10";
								end if;
								xsmall <= '1';
								xe3 <= '0';
								if e(3) = '1' or e(2) = '1' then
									-- the intermediate result in FPTEMP; in ETEMP too for
									-- FMOVE, FABS and FNEG (FMOVE out keeps the source)
									f(68) := x"00";
									f(76) := ix(79 downto 72); f(77) := ix(71 downto 64);
									for i in 0 to 7 loop
										f(80 + i) := ix(63 - 8 * i downto 56 - 8 * i);
									end loop;
									if store = '0' then
										f(60)(7 downto 5) := "000";
										f(88) := ix(79 downto 72); f(89) := ix(71 downto 64);
										for i in 0 to 7 loop
											f(92 + i) := ix(63 - 8 * i downto 56 - 8 * i);
										end loop;
									end if;
								elsif lneg then
									-- the rounded integer, sign-extended, as x_operr checks
									-- it (check_upper)
									f(68) := x"00";
									f(76) := x"C0"; f(77) := x"00";
									f(80) := x"FF"; f(81) := x"FF"; f(82) := x"FF"; f(83) := x"FF";
									v32 := alu_res(31 downto 0);
									if alu_rp = "00" then v32 := x"FFFFFF80"; elsif alu_rp = "01" then v32 := x"FFFF8000"; end if;
									f(84) := v32(31 downto 24); f(85) := v32(23 downto 16);
									f(86) := v32(15 downto 8); f(87) := v32(7 downto 0);
								elsif store = '1' and e(4) = '1' and alu_op = x"A" then
									-- an integer out of range: FPTEMP the largest exponent,
									-- so that the FPSP stores the largest integer of the sign
									f(68) := x"00";
									f(76) := alu_src(79) & "1111111"; f(77) := x"FF";
									for i in 0 to 7 loop
										f(80 + i) := x"00";
									end loop;
								end if;
							end if;
							if store = '1' then
								f(73) := x"10";											-- T
								xst <= '1';
								xpost_r <= '1';
							end if;
							xf <= f;
							xpend <= '1';
						end if;
						if store = '1' then
							state <= ST_STORE;
						else
							state <= ST_FINISH;		-- done was given by alu_early
						end if;
					end if;

				-- FMOVE FPn,<ea>: the converted result to Dn or memory
				when ST_STORE =>
					x := alu_res;
					case fmt is
						when "001" => v32 := x_to_sgl(x);
						when others => v32 := x(31 downto 0);
					end case;
					if fmt = "010" then
						buf(0) <= x(79 downto 72); buf(1) <= x(71 downto 64);
						buf(2) <= x"00"; buf(3) <= x"00";
						for i in 0 to 7 loop
							buf(4 + i) <= x(63 - 8 * i downto 56 - 8 * i);
						end loop;
					elsif fmt = "101" then
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
						xnow <= xst;			-- FMOVE out: the post-instruction exception
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
					-- FRESTORE: a null frame resets the FPU; a busy frame is read
					-- (ST_RESTORE_B); other frames are skipped
					if mode = "011" and buf(1) /= x"00" then
						-- (An)+ skips the rest of a longer frame
						wr_en <= '1'; wr_idx <= 8 + to_integer(unsigned(reg)); wr_size <= "10";
						wr_data <= std_logic_vector(unsigned(areg) + 4 + unsigned(buf(1)));
					end if;
					unimp_pend <= '0';
					busy_pend <= '0';
					xpend <= '0';
					cusave <= x"00"; re1 <= '0'; re3 <= '0'; ru <= '0';
					xf(0) <= buf(0); xf(1) <= buf(1); xf(2) <= buf(2); xf(3) <= buf(3);
					if buf(0) = x"00" then
						fpr <= (others => FP_NAN);
						fpcr <= (others => '0');
						fpsr <= (others => '0');
						fpiar <= (others => '0');
						null_state <= '1';
						done_r <= '1';
						state <= ST_FINISH;
					elsif buf(1) = x"60" then
						null_state <= '0';
						xa <= addr + 4; xi <= 4; xn <= 100; xwr <= '0';
						xrframe <= '1'; xro <= 0; xsmall <= '0';
						state <= ST_XFER; ret_state <= ST_RESTORE_B;
					elsif buf(1) = x"30" then
						-- the 26-word frame: an E1 exception comes back from it
						null_state <= '0';
						xa <= addr + 4; xi <= 4; xn <= 52; xwr <= '0';
						xrframe <= '1'; xro <= 48; xsmall <= '1';
						state <= ST_XFER; ret_state <= ST_RESTORE_B;
					else
						null_state <= '0';
						done_r <= '1';
						state <= ST_FINISH;
					end if;
				when ST_RESTORE_B =>
					-- a busy frame the FPSP left for the 68040 to complete (res_func:
					-- CU_SAVEPC $FE, E1 clear): run the command word on ETEMP and
					-- FPTEMP, the result to its FPn
					opm := cmd1b(6 downto 0);
					e := '0' & op_of(opm);
					if (re1 = '1' or re3 = '1') and ru = '0' then
						-- an exceptional state (U clear): pending again, with the vector the
						-- 68040 derives from it (gen_except of the FPSP: NMCEXC for
						-- E1, the FPSR for E3, else INEX)
						if re3 = '1' then
							xm := "00" & fpsr(12) & fpsr(11) & (fpsr(10) and fpcr(10)) &
							      ((fpsr(9) or fpsr(8)) and (fpcr(9) or fpcr(8)));
						else
							xm := (xf(57)(3) or (fpsr(14) and fpcr(14))) & (xf(57)(2) or (fpsr(13) and fpcr(13))) &
							      (xf(57)(1) or (fpsr(12) and fpcr(12))) & (xf(57)(0) or (fpsr(11) and fpcr(11))) &
							      (fpsr(10) and fpcr(10)) & ((fpsr(9) or fpsr(8)) and (fpcr(9) or fpcr(8)));
						end if;
						xvec_r <= xvec_of(xm);
						xe3 <= re3;
						if re1 = '1' and re3 = '0' and fpsr(15) = '1' and fpcr(15) = '1' then
							xvec_r <= "000";		-- BSUN
						end if;
						xpend <= '1';
						done_r <= '1';
						state <= ST_FINISH;
					elsif xsmall = '0' and cusave = x"FE" and re1 = '0' and re3 = '0' and e(4) = '1' then
						alu_op <= e(3 downto 0);
						cw <= cmd1b;
						if opm(6) = '1' then
							if opm(2) = '1' then alu_rp <= "10"; else alu_rp <= "01"; end if;
						else
							alu_rp <= fpcr(7) & (fpcr(6) and not fpcr(7));	-- 11: double
						end if;
						alu_rm <= fpcr(5 downto 4);
						alu_tomem <= '0';
						alu_src <= frame_x(etemp, xf(60)(4));
						alu_dst <= frame_x(fptemp, xf(68)(4));
						if opm /= "0111000" and opm /= "0111010" then
							wr_fp <= '1';
						end if;
						set_cc <= '1';
						uop <= '0';
						pk <= '0';
						rfun <= '1';
						state <= ST_ALU;
					else
						done_r <= '1';
						state <= ST_FINISH;
					end if;

				when ST_FINISH =>
					state <= IDLE;
				end case;
				end if;
			end if;
		end if;
	end process;
end architecture;
