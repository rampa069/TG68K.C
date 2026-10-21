------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Copyright (c) 2009-2020 Tobias Gubener                                   -- 
-- Patches by MikeJ, Till Harbaum, Rok Krajnk, ...                          --
-- Subdesign fAMpIGA by TobiFlex                                            --
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU Lesser General Public License as published --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
-- This source file is distributed in the hope that it will be useful,      --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of           --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            --
-- GNU General Public License for more details.                             --
--                                                                          --
-- You should have received a copy of the GNU General Public License        --
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

-- 14.10.2020 TG bugfix chk2.b
-- 13.10.2020 TG go back to old aligned design and bugfix chk2
-- 11.10.2020 TG next try CHK2 flags
-- 10.10.2020 TG bugfix division N-flag
-- 09.10.2020 TG bugfix division overflow
-- 2/3.10.2020 some tweaks by retrofun, gyurco and robinsonb5
-- 17.03.2020 TG bugfix move data to (extended address)
-- 13.03.2020 TG bugfix extended addess mode - thanks Adam Polkosnik
-- 15.02.2020 TG bugfix DIVS.W with result $8000
-- 08.01.2020 TH fix the byte-mirroring
-- 25.11.2019 TG bugfix ILLEGAL.B handling
-- 24.11.2019 TG next try CMP2 and CHK2.l
-- 24.11.2019 retrofun(RF) commit ILLEGAL.B handling 
-- 18.11.2019 TG insert CMP2 and CHK2.l
-- 17.11.2019 TG insert CAS and CAS2
-- 10.11.2019 TG insert TRAPcc
-- 08.11.2019 TG bugfix movem in 68020 mode
-- 06.11.2019 TG bugfix CHK
-- 06.11.2019 TG bugfix flags and stackframe DIVU
-- 04.11.2019 TG insert RTE from TH
-- 03.11.2019 TG insert TrapV from TH 
-- 03.11.2019 TG bugfix MUL 64Bit 
-- 03.11.2019 TG rework barrel shifter - some other tweaks
-- 02.11.2019 TG bugfig N-Flag and Z-Flag for DIV
-- 30.10.2019 TG bugfix RTR in 68020-mode
-- 30.10.2019 TG bugfix BFINS again
-- 19.10.2019 TG insert some bugfixes from apolkosnik
-- 05.12.2018 TG insert RTD opcode
-- 03.12.2018 TG insert barrel shifter
-- 01.11.2017 TG bugfix V-Flag for ASL/ASR - thanks Peter Graf
-- 29.05.2017 TG decode 0x4AFB as illegal, needed for QL BKP - thanks Peter Graf
-- 21.05.2017 TG insert generic for hardware multiplier for MULU & MULS
-- 04.04.2017 TG change GPL to LGPL
-- 04.04.2017 TG BCD handling with all undefined behavior! 
-- 02.04.2017 TG bugfix Bitfield Opcodes 
-- 19.03.2017 TG insert PACK/UNPACK  
-- 19.03.2017 TG bugfix CMPI ...(PC) - thanks Till Harbaum
--     ???    MJ bugfix non_aligned movem access
-- add berr handling 10.03.2013 - needed for ATARI Core

-- bugfix session 07/08.Feb.2013
-- movem ,-(an)
-- movem (an)+,          - thanks  Gerhard Suttner
-- btst dn,#data         - thanks  Peter Graf
-- movep                 - thanks  Till Harbaum
-- IPL vector            - thanks  Till Harbaum
--  

-- optimize Register file

-- to do 68010:
-- (MOVEC)
-- BKPT
-- MOVES
--
-- to do 68020:
-- (CALLM)
-- (RETM)

-- bugfix CHK2, CMP2
-- rework barrel shifter 
-- CHK2
-- CMP2
-- cpXXX Coprozessor stuff

-- done 020:
-- CAS, CAS2
-- TRAPcc
-- PACK
-- UNPK
-- Bitfields
-- address modes
-- long bra
-- DIVS.L, DIVU.L
-- LINK long
-- MULS.L, MULU.L
-- extb.l

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use work.TG68K_Pack.all;

entity TG68KdotC_Kernel is
	generic(
		SR_Read : integer:= 2;				--0=>user,		1=>privileged,		2=>switchable with CPU(0)
		VBR_Stackframe : integer:= 2;		--0=>no,			1=>yes/extended,	2=>switchable with CPU(0)
		extAddr_Mode : integer:= 2;		--0=>no,			1=>yes,				2=>switchable with CPU(1)
		MUL_Mode : integer := 2;			--0=>16Bit,		1=>32Bit,			2=>switchable with CPU(1),  3=>no MUL,  
		DIV_Mode : integer := 2;			--0=>16Bit,		1=>32Bit,			2=>switchable with CPU(1),  3=>no DIV,  
		BitField : integer := 2;			--0=>no,			1=>yes,				2=>switchable with CPU(1) 
		
		BarrelShifter : integer := 1;		--0=>no,			1=>yes,				2=>switchable with CPU(1)  
		MUL_Hardware : integer := 1;		--0=>no,			1=>yes,  
		-- 1 keeps the MiSTer Minimig data cache switch, bit 8 of the 68020 CACR
		-- (the 68030 ED bit), readable and driving D_CACHE_out
		D_Cache_Bit : integer := 0;
		-- 68040 FPU: 1 as the MC68040, leaving to the M68040FPSP what it leaves
		-- (OVFL, UNFL, denormalized operands...); 0 completes it all in hardware
		FPU_FPSP : integer := 1
		);
	port(clk						: in std_logic;
		nReset					: in std_logic;			--low active
		clkena_in				: in std_logic:='1';
		data_in					: in std_logic_vector(15 downto 0);
		IPL						: in std_logic_vector(2 downto 0):="111";
		IPL_autovector			: in std_logic:='0';
		berr						: in std_logic:='0';					-- only 68000 Stackpointer dummy
		CPU						: in std_logic_vector(1 downto 0):="00";  -- 00->68000  01->68010  11->68020(only some parts - yet)
		addr_out					: out std_logic_vector(31 downto 0);
		data_write				: out std_logic_vector(15 downto 0);
		nWr						: out std_logic;
		nUDS						: out std_logic;
		nLDS						: out std_logic;
		busstate					: out std_logic_vector(1 downto 0);	-- 00-> fetch code 10->read data 11->write data 01->no memaccess
		longword					: out std_logic;
		newpc						: out std_logic;	-- the PC is about to be loaded (MinimigAGA's prefetch)
		-- 32-bit data bus (optional): long_req asks for an aligned long data
		-- access in one bus cycle, the memory answers long_ack in that cycle
		-- with the low word (address+2) on data_in_lo and the high word on
		-- data_in as usual (reads), or takes data_write_lo with data_write
		-- (writes); with long_ack at '0' nothing changes. long_ack only
		-- selects at the end of the paths (clock enables and register inputs),
		-- so it can come straight from the memory's acknowledge registers
		long_req					: out std_logic;
		long_ack					: in std_logic := '0';
		data_in_lo				: in std_logic_vector(15 downto 0) := (others => '0');
		data_write_lo			: out std_logic_vector(15 downto 0);
		nResetOut				: out std_logic;
		FC							: out std_logic_vector(2 downto 0);
		clr_berr					: out std_logic;
-- for debug
		skipFetch				: out std_logic;
		regin_out				: out std_logic_vector(31 downto 0);
		CACR_out					: out std_logic_vector( 3 downto 0);
		D_CACHE_out				: out std_logic;	-- data cache enable (CACR bit 8, or DE in the 68040 mode)
		VBR_out					: out std_logic_vector(31 downto 0);
		MMU_on_out				: out std_logic	-- 68040 mode, TC.E set: VBR and the vector fetches are logical addresses
		);
end TG68KdotC_Kernel;

architecture logic of TG68KdotC_Kernel is


	signal use_VBR_Stackframe	: std_logic;

	signal syncReset			: std_logic_vector(3 downto 0);
	signal Reset				: std_logic;
	signal clkena_lw			: std_logic;
	signal TG68_PC				: std_logic_vector(31 downto 0);
	signal tmp_TG68_PC		: std_logic_vector(31 downto 0);
	signal TG68_PC_add		: std_logic_vector(31 downto 0);
	signal PC_dataa			: std_logic_vector(31 downto 0);
	signal PC_datab			: std_logic_vector(31 downto 0);
	signal memaddr				: std_logic_vector(31 downto 0);
	signal state				: std_logic_vector(1 downto 0);
	signal datatype			: std_logic_vector(1 downto 0);
	signal set_datatype		: std_logic_vector(1 downto 0);
	signal exe_datatype		: std_logic_vector(1 downto 0);
	signal setstate			: std_logic_vector(1 downto 0);
	signal setaddrvalue		: std_logic;
	signal addrvalue			: std_logic;

	signal opcode				: std_logic_vector(15 downto 0);
	signal exe_opcode			: std_logic_vector(15 downto 0);
	signal sndOPC				: std_logic_vector(15 downto 0);

	signal exe_pc				: std_logic_vector(31 downto 0);--TH
	signal last_opc_pc		: std_logic_vector(31 downto 0);--TH
	signal last_opc_read		: std_logic_vector(15 downto 0);
	signal registerin			: std_logic_vector(31 downto 0);
	signal reg_QA				: std_logic_vector(31 downto 0);
	signal reg_QB				: std_logic_vector(31 downto 0);
	signal Wwrena,Lwrena		: bit;
	signal Bwrena				: bit;
	signal Regwrena_now		: bit;
	signal rf_dest_addr		: std_logic_vector(3 downto 0);
	signal rf_source_addr	: std_logic_vector(3 downto 0);
	signal rf_source_addrd	: std_logic_vector(3 downto 0);
   
	signal regin				: std_logic_vector(31 downto 0);
	type   regfile_t is array(0 to 15) of std_logic_vector(31 downto 0);
	signal regfile				: regfile_t := (OTHERS => (OTHERS => '0')); -- mikej stops sim X issues;
	signal RDindex_A			: integer range 0 to 15;
	signal RDindex_B			: integer range 0 to 15;
	signal WR_AReg				: std_logic;


	signal addr					: std_logic_vector(31 downto 0);
	signal memaddr_reg		: std_logic_vector(31 downto 0);
	signal memaddr_delta		: std_logic_vector(31 downto 0);
	signal memaddr_delta_rega	: std_logic_vector(31 downto 0);
	signal memaddr_delta_regb	: std_logic_vector(31 downto 0);
	signal use_base			: bit;
	
	signal ea_data				: std_logic_vector(31 downto 0);
	signal OP1out				: std_logic_vector(31 downto 0);
	signal OP2out				: std_logic_vector(31 downto 0);
	signal OP1outbrief		: std_logic_vector(15 downto 0);
	signal OP1in				: std_logic_vector(31 downto 0);
	signal ALUout	: std_logic_vector(31 downto 0);
	signal data_write_tmp	: std_logic_vector(31 downto 0);
	signal data_write_muxin	: std_logic_vector(31 downto 0);
	signal data_write_mux	: std_logic_vector(47 downto 0);
	signal nextpass			: bit;
	signal setnextpass		: bit;
	signal setdispbyte		: bit;
	signal setdisp				: bit;
	signal regdirectsource	:bit;		-- checken !!!
	signal addsub_q			: std_logic_vector(31 downto 0);
	signal briefdata			: std_logic_vector(31 downto 0);
	signal c_out				: std_logic_vector(2 downto 0);

	signal mem_address		: std_logic_vector(31 downto 0);
	signal memaddr_a			: std_logic_vector(31 downto 0);

	signal TG68_PC_brw		: bit;
	signal TG68_PC_word		: bit;
	signal getbrief			: bit;
	signal brief				: std_logic_vector(15 downto 0);
	signal data_is_source	: bit;
	signal store_in_tmp		: bit;
	signal write_back			: bit;
	signal exec_write_back	: bit;
	signal setstackaddr		: bit;
	signal writePC				: bit;
	signal writePCbig			: bit;
	signal set_writePCbig	: bit;
	signal writePCnext		: bit;
	signal setopcode			: bit;
	signal decodeOPC			: bit;
	signal execOPC				: bit;
	signal execOPC_ALU		: bit;
	signal setexecOPC			: bit;
	signal endOPC				: bit;
	signal setendOPC			: bit;
	signal Flags				: std_logic_vector(7 downto 0);	-- ...XNZVC
	signal FlagsSR				: std_logic_vector(7 downto 0);	-- T.S.0III
	signal SRin					: std_logic_vector(7 downto 0);
	signal exec_DIRECT		: bit;
	signal exec_tas			: std_logic;
	signal set_exec_tas		: std_logic;

	signal exe_condition		: std_logic;
	signal ea_only				: bit;
	signal source_areg		: std_logic;
	signal source_lowbits	: bit;
	signal source_LDRLbits 	: bit;
	signal source_LDRMbits 	: bit;
	signal source_2ndHbits	: bit;
	signal source_2ndMbits	: bit;
	signal source_2ndLbits	: bit;
	signal dest_areg			: std_logic;
	signal dest_LDRareg		: std_logic;
	signal dest_LDRHbits		: bit;
	signal dest_LDRLbits		: bit;
	signal dest_2ndHbits		: bit;
	signal dest_2ndLbits		: bit;
	signal dest_hbits			: bit;
	signal rot_bits			: std_logic_vector(1 downto 0);
	signal set_rot_bits		: std_logic_vector(1 downto 0);
	signal rot_cnt				: std_logic_vector(5 downto 0);
	signal set_rot_cnt		: std_logic_vector(5 downto 0);
	signal movem_actiond		: bit;
	signal movem_regaddr		: std_logic_vector(3 downto 0);
	signal movem_mux			: std_logic_vector(3 downto 0);
	signal movem_presub		: bit;
	signal movem_run			: bit;
	signal ea_calc_b			: std_logic_vector(31 downto 0);
	signal set_direct_data	: bit;
	signal use_direct_data	: bit;
	signal direct_data		: bit;

	signal set_V_Flag			: bit;
	signal set_vectoraddr	: bit;
	signal writeSR				: bit;
	signal trap_berr			: bit;
	signal trap_illegal		: bit;
	signal trap_addr_error	: bit;
	signal trap_priv			: bit;
	signal trap_trace			: bit;
	signal trap_1010			: bit;
	signal trap_1111			: bit;
	signal trap_fmt			: bit;					-- RTE with a frame format it cannot restore
	signal trap_unsupp		: bit;					-- FP unsupported data type, vector 55
	-- FP arithmetic exception, vectors 48-54 (testbed-9bf.16): from the FPU
	-- (fpu_trapx; post-instruction with format $3 when fpu_xpost), or at
	-- the decode of an FBcc with one pending or a BSUN to take (fpu_fbx);
	-- fpu_tx marks the entry of a pre-instruction one (format $0, the PC of
	-- the instruction)
	signal trap_fpx			: bit;
	signal fpu_xexc, fpu_xpost, fpu_xpend, fpu_nan, fpu_bsun_en, fpu_set_bsun : std_logic;
	signal fpu_xvec, fpu_xpvec, fpx_v : std_logic_vector(2 downto 0);
	signal fpu_trapx, fpu_fbx	: std_logic;
	signal fpu_xhere			: std_logic;
	signal fpu_tx				: std_logic := '0';
	signal fpu_unsupp, fpu_upost : std_logic;
	signal fpu_trap55			: std_logic;
	signal fpu_tu				: std_logic := '0';		-- its exception entry
	signal fmt_err				: std_logic := '0';		-- the format error frame is being built
	signal rte_ccr				: std_logic_vector(7 downto 0);	-- the CCR before an RTE
	signal rte_sr				: std_logic_vector(7 downto 0);	-- the SR before an RTE
	signal trap_trap			: bit;
	signal trap_trapv			: bit;
	signal trap_interrupt	: bit;
	signal trapmake			: bit;
	signal trapd				: bit;
	signal trap_SR				: std_logic_vector(7 downto 0);
	signal make_trace			: std_logic;
	signal make_berr			: std_logic;
	signal useStackframe2	: std_logic;
	
	signal set_stop			: bit;
	signal stop					: bit;
	signal trap_vector		: std_logic_vector(31 downto 0);
	signal trap_vector_vbr	: std_logic_vector(31 downto 0);
	signal USP					: std_logic_vector(31 downto 0);
	-- 68020 and later: the supervisor stack pointer SR.M does not select, the
	-- MSP when M is 0 and the ISP when M is 1 (the one it selects is A7 in
	-- supervisor mode, USP above in user mode, which then holds it)
	signal OSP					: std_logic_vector(31 downto 0);
	signal preMmode			: std_logic;	-- the M that A7/USP and OSP stand for
	signal set_chgM			: bit;			-- swap them: SR.M changed
	signal exec_chgM			: bit;
	signal chgM_S				: std_logic;	-- with S before the swap
	signal thr_pass			: bit;			-- interrupt with M set: the throwaway frame on the ISP
--	signal illegal_write_mode	: bit;
--	signal illegal_read_mode	: bit;
--	signal illegal_byteaddr		: bit;

	signal IPL_nr				: std_logic_vector(2 downto 0);
	signal rIPL_nr				: std_logic_vector(2 downto 0);
	signal ipl7_last			: bit;			-- IPL was 7 on the previous clock
	signal nmi_pending			: bit;			-- a rise to level 7 not yet taken
	signal IPL_vec				: std_logic_vector(7 downto 0);
	signal interrupt			: bit;
	signal setinterrupt		: bit;
	signal SVmode				: std_logic;
	signal preSVmode			: std_logic;
	signal Suppress_Base		: bit;
	signal set_Suppress_Base: bit;
	signal set_Z_error 		: bit;
	signal Z_error 			: bit;
	signal ea_build_now		: bit;	
	signal build_logical		: bit;	
	signal build_bcd			: bit;	
	
	signal data_read			: std_logic_vector(31 downto 0);
	signal data_read_w		: std_logic_vector(31 downto 0);	-- data_read of word cycles
	signal addr_p2				: std_logic_vector(31 downto 0);	-- next word of a long
	signal bf_ext_in			: std_logic_vector(7 downto 0);
	signal bf_ext_out			: std_logic_vector(7 downto 0);
--	signal byte					: bit;
	signal long_start			: bit;
	signal long_start_alu	: bit;
	signal non_aligned		: std_logic;
	signal check_aligned		: std_logic;
	signal long_done			: bit;
	signal memmask				: std_logic_vector(5 downto 0);
	signal set_memmask		: std_logic_vector(5 downto 0);
	signal memread				: std_logic_vector(3 downto 0);
	signal wbmemmask			: std_logic_vector(5 downto 0);
	signal memmaskmux			: std_logic_vector(5 downto 0);
	signal oddout				: std_logic;
	signal set_oddout			: std_logic;
	signal PCbase				: std_logic;
	signal set_PCbase			: std_logic;
		 
	signal last_data_read	: std_logic_vector(31 downto 0);
	signal last_data_in		: std_logic_vector(31 downto 0);

	signal bf_offset			: std_logic_vector(5 downto 0);
	signal bf_width			: std_logic_vector(5 downto 0);
	signal bf_bhits			: std_logic_vector(5 downto 0);
	signal bf_shift			: std_logic_vector(5 downto 0);
	signal alu_width			: std_logic_vector(5 downto 0);
	signal alu_bf_shift		: std_logic_vector(5 downto 0);
	signal bf_loffset			: std_logic_vector(5 downto 0);
	signal bf_full_offset	: std_logic_vector(31 downto 0);
	signal alu_bf_ffo_offset: std_logic_vector(31 downto 0);
	signal alu_bf_loffset	: std_logic_vector(5 downto 0);

	signal movec_data			: std_logic_vector(31 downto 0);
	signal VBR					: std_logic_vector(31 downto 0);
	signal CACR					: std_logic_vector(3 downto 0);
	signal DFC					: std_logic_vector(2 downto 0);
	signal SFC					: std_logic_vector(2 downto 0);
	-- 68040 mode (CPU = "10"): the 68040 CACR and the MMU registers, which
	-- nothing acts on yet
	signal cpu010				: std_logic;	-- 68010 or later
	signal cpu040				: std_logic;
	-- (zero at power-up, as FPGA registers are)
	signal CACR040				: std_logic_vector(1 downto 0) := "00";	-- DE, IE
	signal CACR_DC				: std_logic;
	signal CACR_DC_owned		: std_logic;
	signal skipFetch_i			: std_logic;			-- a cycle MinimigAGA takes as internal
	signal cinv040				: std_logic := '0';		-- a CINV or CPUSH ran: CACR_out bit 3
	signal cinv_pend			: std_logic := '0';
	signal cinv_cnt			: integer range 0 to 255 := 0;
	signal TC040				: std_logic := '0';				-- P (E is kept clear)
	signal ITT0, ITT1, DTT0, DTT1 : std_logic_vector(31 downto 0) := (others => '0');
	signal MMUSR, URP, SRP	: std_logic_vector(31 downto 0) := (others => '0');
	signal movec_ok			: std_logic;
	-- MOVE16 (68040): a small bus sequencer copies the 16-byte line while the
	-- microcode waits in m16_wait
	type m16_buf_t is array(0 to 7) of std_logic_vector(15 downto 0);
	signal m16_buf			: m16_buf_t;
	signal m16_active		: std_logic := '0';
	signal m16_done			: std_logic := '0';
	signal m16_step			: std_logic_vector(3 downto 0) := "0000";	-- 0-7 reads, 8-15 writes
	signal m16_src, m16_dst	: std_logic_vector(31 downto 0);
	signal m16_lo				: std_logic_vector(15 downto 0);
	signal m16_addr			: std_logic_vector(31 downto 0);
	signal m16_last			: std_logic;
	signal m16_inc_x, m16_inc_y : std_logic;
	signal m16_rx, m16_ry	: integer range 8 to 15;
	signal addr_out_core	: std_logic_vector(31 downto 0);
	-- 68040 MMU (TG68K_MMU) between the core and the bus
	signal clkena_core		: std_logic;
	-- address error (68000): ae_now flags the core's access starting in this
	-- cycle, which is not performed; ae_frame holds until the handler starts,
	-- for the group 0 frame (MC68000 User's Manual, figure 6-7)
	signal ae_now				: std_logic;
	-- 68040 access error (MMU fault): acc_now flags a faulting access of the
	-- core or the FPU in this cycle. A data access aborts the instruction at
	-- once (acc_restart: the registers go back to rf_shadow, taken at its
	-- decode). A fetch is only noted (acc_fpend), and the cycle after says
	-- what it was, from registers alone (the decode logic would put the data
	-- bus on the path to every register): with decodeOPC it was the next
	-- opcode, the instruction before has completed and acc_go takes the
	-- exception with that opcode's address; otherwise it was a word of the
	-- current instruction, which acc_late aborts and restarts; an interrupt
	-- taken instead drops the fault (the fetch is made again). xc_now is any
	-- of the entries that end the instruction at once (address or access
	-- error).
	signal acc_now, acc_restart, acc_late, acc_go, xc_now : std_logic;
	signal acc_frame, acc_fpend	: std_logic := '0';
	signal acc_pc, acc_fa		: std_logic_vector(31 downto 0);
	signal acc_ssw				: std_logic_vector(15 downto 0);
	signal acc_srh				: std_logic_vector(7 downto 0);
	signal acc_ccr				: std_logic_vector(7 downto 0);
	signal acc_lw2				: std_logic := '0';		-- the first word of a long access is done
	-- a faulting data write is held as a pending write-back, as on the 68040
	-- (UM 8.4.6, table 8-6, write page fault): acc_wdefer says the write may be
	-- (one write of an instruction that writes once), acc_wpend that one is
	-- held: the instruction completes with its later writes suppressed, and
	-- the exception is taken at the decode of the next one, with that one's
	-- address as PC and the write in WB2 (acc_wb2*); RTE goes on after it
	signal acc_wdefer, acc_wpend	: std_logic := '0';
	signal acc_wb					: std_logic := '0';		-- WB2 valid in the frame
	signal acc_m16w				: std_logic := '0';		-- a MOVE16 write fault: PD0-PD3
	signal acc_wb2s				: std_logic_vector(7 downto 0);
	-- a physical bus error (TEA on berr, 68040 mode): an access error with
	-- ATC clear; a write is held in WB1, memory aligned (UM table 8-6, normal
	-- write physical bus error)
	signal acc_tea, acc_wb1		: std_logic := '0';
	signal acc_wb1s				: std_logic_vector(7 downto 0);
	signal acc_wb1d				: std_logic_vector(31 downto 0);
	-- MOVEM: CM in the SSW and the effective address in the frame (UM 8.4.6.2)
	signal acc_cm					: std_logic := '0';
	signal acc_ea, movem_ea		: std_logic_vector(31 downto 0);
	signal movem_first			: std_logic := '0';
	signal acc_wb2a, acc_wb2d	: std_logic_vector(31 downto 0);
	signal rf_shadow			: regfile_t;
	signal long_spec, long_req_i, long_fast	: std_logic;
	-- A7 after an RTE format error (- 8) or a format $7 frame (+ 52), and
	-- MOVE16's An + 16, worked out a state earlier so that the register file
	-- inputs take registers and no adder
	signal sp_adj, m16_ax, m16_ay	: std_logic_vector(31 downto 0);
	-- the frame words of the address and access errors, from registers only,
	-- so that they add one level to the data_write_tmp path
	signal fr_sel, fr_lo, fr_sf2	: std_logic;
	signal fr_word				: std_logic_vector(31 downto 0);
	signal ae_frame			: std_logic := '0';
	signal ae_addr, ae_pc	: std_logic_vector(31 downto 0);
	-- the stacked PC of the address error is ae_base + ae_off: only a choice
	-- of registers is latched under the clock enable (which comes late from
	-- the memory system in MinimigAGA), the addition is made from registers
	signal ae_base, ae_off	: std_logic_vector(31 downto 0);
	signal ae_status			: std_logic_vector(15 downto 0);
	signal ae_ir				: std_logic_vector(15 downto 0);
	signal ae_sr				: std_logic_vector(15 downto 0);
	-- 68010 and 68020 frames: the words below the format word, pushed by
	-- ae_push from the last (ae_cnt) to the first (index 0, at SP+8)
	signal ae_cnt				: integer range 0 to 31;
	signal ae_xword			: std_logic_vector(15 downto 0);
	signal ae_ssw				: std_logic_vector(15 downto 0);
	signal ae_dob				: std_logic_vector(15 downto 0);	-- data output buffer
	signal ae_ccr_force		: std_logic;
	signal ae_ccr				: std_logic_vector(4 downto 0);
	signal ccr_force			: std_logic;
	signal ccr_val				: std_logic_vector(4 downto 0);
	signal ae_fix				: std_logic;					-- An of the faulting access to correct
	signal ae_fix_idx			: integer range 0 to 15;
	signal ae_fix_val			: std_logic_vector(31 downto 0);
	signal ae_fix_r				: std_logic := '0';				-- the same, registered for ae_fix1
	signal ae_fix_idx_r		: integer range 0 to 15;
	signal ae_fix_val_r		: std_logic_vector(31 downto 0);
	signal ae_read_done		: std_logic := '0';		-- a data read of this instruction completed
	signal ae_faddr			: std_logic_vector(31 downto 0);	-- the fault address as the 68000 has it
	signal ae_move_w			: std_logic;					-- a MOVE whose write faults
	signal ae_srcext			: integer range 0 to 4;		-- bytes of its source extension words
	signal TC040E				: std_logic := '0';
	signal bus_l				: std_logic_vector(1 downto 0);	-- the core's access, logical
	signal addr_l				: std_logic_vector(31 downto 0);
	signal nwr_l, nuds_l, nlds_l : std_logic;
	signal dwr_l				: std_logic_vector(15 downto 0);
	signal mmu_act, mmu_stall, mmu_quiet, mmu_fault, mmu_fault_pend : std_logic;
	signal mmu_pflush_page		: std_logic;
	signal mmu_fc				: std_logic_vector(2 downto 0);
	signal fc_int				: std_logic_vector(2 downto 0);
	signal mmu_paddr, mmu_baddr, mmu_mmusr : std_logic_vector(31 downto 0);
	signal mmu_bact, mmu_bwr	: std_logic;
	signal mmu_bwdata			: std_logic_vector(15 downto 0);
	signal mmu_ptest, mmu_ptest_done, mmu_pflush, mmu_pflush_all : std_logic;
	signal mmu_wr, mmu_ptest_wr	: std_logic;
	signal mmu_ptest_addr		: std_logic_vector(31 downto 0);
	-- 68040 FPU (TG68K_FPU): the kernel decodes, builds the effective address
	-- of the modes it shares with the integer unit and waits in fpu_wait
	signal fpu_ins				: std_logic;	-- cpGEN, FSAVE or FRESTORE of the FPU
	signal fpu_gen				: std_logic;	-- cpGEN (a command word follows)
	signal fpu_memea			: std_logic;	-- effective address built by the kernel
	signal fpu_fbcc				: std_logic;
	signal fpu_unimpl			: std_logic;
	signal fpu_badcmd, fpu_lf	: std_logic;	-- the command word of an unimplemented one
	signal fpu_start, fpu_done, fpu_jump : std_logic;
	signal fpu_br : std_logic;
	signal fpu_unimp, fpu_trap2, fpu_tf : std_logic := '0';
	signal fpu_ftrap, fpu_ftrapcc, fpu_tfp, fpu_bsun : std_logic := '0';
	signal fpu_ea_out : std_logic_vector(31 downto 0);
	signal fpu_br_target, fpu_target : std_logic_vector(31 downto 0);
	signal fpu_ea_r, fpu_ea, fpu_next_pc : std_logic_vector(31 downto 0);
	signal fpu_ext				: integer range 0 to 16;	-- bytes of EA extension and immediate data
	signal fpu_rd_idx, fpu_wr_idx : integer range 0 to 15;
	signal fpu_rd_data, fpu_wr_data : std_logic_vector(31 downto 0);
	signal fpu_wr_en			: std_logic;
	signal fpu_wr_size			: std_logic_vector(1 downto 0);
	signal fpu_bus_act, fpu_bus_wr, fpu_uds_n, fpu_lds_n : std_logic;
	signal fpu_bus_addr		: std_logic_vector(31 downto 0);
	signal fpu_bus_wdata		: std_logic_vector(15 downto 0);
	signal fpu_pred				: std_logic_vector(5 downto 0);
	signal fpu_pred_true		: std_logic;
	signal data_write_core	: std_logic_vector(15 downto 0);
	

	signal set					: bit_vector(lastOpcBit downto 0);
	signal set_exec			: bit_vector(lastOpcBit downto 0);
	signal exec					: bit_vector(lastOpcBit downto 0);

	signal micro_state		: micro_states;
	signal next_micro_state	: micro_states;
	


BEGIN  

ALU: TG68K_ALU   
	generic map(
		MUL_Mode => MUL_Mode,				--0=>16Bit,	1=>32Bit,	2=>switchable with CPU(1),		3=>no MUL,
		MUL_Hardware => MUL_Hardware,		--0=>no,		1=>yes,
		DIV_Mode => DIV_Mode,				--0=>16Bit,	1=>32Bit,	2=>switchable with CPU(1),		3=>no DIV,
		BarrelShifter => BarrelShifter	--0=>no,		1=>yes,		2=>switchable with CPU(1)  
		)
	port map(
		clk => clk,								--: in std_logic;
		Reset => Reset,						--: in std_logic;
		CPU => CPU,								--: in std_logic_vector(1 downto 0):="00";  -- 00->68000  01->68010  11->68020(only some parts - yet)
		clkena_lw => clkena_lw,				--: in std_logic:='1';
		execOPC => execOPC_ALU,				--: in bit;
		decodeOPC => decodeOPC,				--: in bit;
		exe_condition => exe_condition,	--: in std_logic;
		exec_tas => exec_tas,				--: in std_logic;
		long_start => long_start_alu,		--: in bit;
		long_fast => to_bit(long_spec),
		non_aligned => non_aligned,
		check_aligned => check_aligned,
		movem_presub => movem_presub,		--: in bit;
		set_stop => set_stop,				--: in bit;
		Z_error => Z_error,					--: in bit;

		rot_bits => rot_bits,				--: in std_logic_vector(1 downto 0);
		exec => exec,							--: in bit_vector(lastOpcBit downto 0);
		OP1out => OP1out,						--: in std_logic_vector(31 downto 0);
		OP2out => OP2out,						--: in std_logic_vector(31 downto 0);
		reg_QA => reg_QA,						--: in std_logic_vector(31 downto 0);
		reg_QB => reg_QB,						--: in std_logic_vector(31 downto 0);
		opcode => opcode,						--: in std_logic_vector(15 downto 0);
		exe_opcode => exe_opcode,			--: in std_logic_vector(15 downto 0);
		exe_datatype => exe_datatype,		--: in std_logic_vector(1 downto 0);
		sndOPC => sndOPC,						--: in std_logic_vector(15 downto 0);
		last_data_read => last_data_read(15 downto 0),	--: in std_logic_vector(31 downto 0);
		data_read => data_read(15 downto 0),		 		--: in std_logic_vector(31 downto 0);
		FlagsSR => FlagsSR,					--: in std_logic_vector(7 downto 0);
		micro_state => micro_state,		--: in micro_states;  
		bf_ext_in => bf_ext_in,
		bf_ext_out => bf_ext_out,
		bf_shift => alu_bf_shift,
		bf_width => alu_width,
		bf_ffo_offset => alu_bf_ffo_offset,
		bf_loffset => alu_bf_loffset(4 downto 0),

		set_V_Flag => set_V_Flag,			--: buffer bit;
		Flags => Flags,					 	--: buffer std_logic_vector(8 downto 0);
		ccr_force => ccr_force,
		ccr_val => ccr_val,
		c_out => c_out,					 	--: buffer std_logic_vector(2 downto 0);
		addsub_q => addsub_q,				--: buffer std_logic_vector(31 downto 0);
		ALUout => ALUout						--: buffer std_logic_vector(31 downto 0)
	);

	-- AMR - let the parent module know this is a longword access.  (Easy way to enable burst writes.)
	-- Only for a cycle of the core: MinimigAGA's cache holds a write made with
	-- it and takes the next write as its low word, while a table search of the
	-- MMU (the U and M write of a descriptor), the FPU and MOVE16 write single
	-- words under the core's pending long
	longword <= '1' WHEN memmaskmux(3)='0' AND mmu_bact='0' AND fpu_bus_act='0' AND m16_active='0' ELSE '0';
	
	-- a long data access that can be done in one bus cycle: the first word
	-- of a long (memmaskmux(3) clear, not a 3-word bit field access), aligned
	-- to 4 bytes, by the core itself, and not a sequence that steps the
	-- address word by word (mem_addsub), whose next address assumes two word
	-- cycles, other than MOVEM (whose step the ALU makes 4 with long_fast)
	long_spec <= '1' WHEN state(1)='1' AND memmaskmux(3)='0' AND memmaskmux(1)='1' AND addr(1 downto 0)="00" AND
	                      fpu_bus_act='0' AND m16_active='0' AND (exec(movem_action)='1' OR exec(mem_addsub)='0') ELSE '0';
	-- (only a cycle of the core on the bus; the MMU terms stay out of
	-- long_spec, which the data path uses, as they come from the TLB lookup)
	long_req_i <= long_spec AND NOT mmu_stall AND NOT mmu_bact AND NOT mmu_quiet;
	long_req <= long_req_i;
	long_fast <= long_req_i AND long_ack;
	addr_p2 <= addr + 2;
	-- The data path works out a possible long as if it came in one cycle
	-- (long_spec, from the core's registers); without long_fast clkena_lw
	-- stays low and that result is dropped, and the registers loaded on
	-- clkena_core choose with long_fast right at their inputs. So long_ack
	-- never runs through the ALU. The ALU sees the cycle as the second word
	-- (+4 for (An)+ and -(An)).
	long_start_alu <= to_bit(NOT memmaskmux(3) AND NOT long_spec);
	execOPC_ALU <= execOPC OR exec(alu_exec);
	process (memmaskmux)
	begin
		non_aligned <= '0';
		if (memmaskmux(5 downto 4) = "01") or (memmaskmux(5 downto 4) = "10") then
			non_aligned <= '1';
		end if;
	end process;
-----------------------------------------------------------------------------
-- Bus control
-----------------------------------------------------------------------------
   regin_out <= regin;


	-- CPU: 00 68000, 01 68010, 11 68020, 10 68040. The 68040 has every
	-- 68010 and 68020 feature the core models (cpu(1) set), so the 68010
	-- checks use cpu010 instead of cpu(0).
	cpu010 <= cpu(0) OR cpu(1);
	cpu040 <= cpu(1) AND NOT cpu(0);
	-- high when the PC is about to be loaded rather than incremented (as in
	-- MinimigAGA's TG68KdotC_Kernel_experimental, whose prefetch address
	-- generator only follows the CPU while it is high), and also for the jump
	-- after an FPU instruction, the one load of TG68_PC added here
	newpc <= '1' WHEN exec(directPC)='1' OR exec(ea_to_pc)='1' OR TG68_PC_brw='1' OR fpu_jump='1' ELSE '0';

	-- a word or long data access starts with memmask(5) set and memmask(3)
	-- clear (byte accesses have memmask(3) set); instruction fetches are
	-- words. Only the 68000 mode traps; exception processing itself is not
	-- checked (a second fault there would halt a real 68000).
	-- the 68040 traps only an instruction prefetch at an odd address (M68040
	-- User's Manual 8.2.2); its data accesses may be misaligned
	ae_now <= '1' WHEN ae_frame='0' AND addr(0)='1' AND fpu_bus_act='0' AND m16_active='0' AND
	                   ((cpu(1)='0' AND (state="00" OR (state(1)='1' AND memmask(5)='1' AND memmask(3)='0'))) OR
	                    (cpu(1)='1' AND state="00")) ELSE '0';

	-- an MMU fault on an access of the core or the FPU (not MOVE16, not during
	-- exception processing: a fault there is not reported)
	-- (nor while a fetch fault is pending)
	acc_tea <= '1' WHEN cpu040='1' AND berr='1' AND mmu_bact='0' AND bus_l/="01" ELSE '0';
	acc_now <= '1' WHEN cpu040='1' AND (mmu_quiet='1' OR acc_tea='1') AND ae_frame='0' AND acc_frame='0' AND
	                    acc_fpend='0' AND acc_wpend='0' ELSE '0';
	-- a write that is held instead of restarting the instruction: not MOVEM,
	-- MOVEP or a bit field (more than one write), not TAS or CAS/CAS2 (locked),
	-- not the FPU or MOVE16, not exception processing
	acc_wdefer <= '1' WHEN state="11" AND fpu_bus_act='0' AND m16_active='0' AND
	                       opcode(15 downto 7)/="010010001" AND
	                       NOT (opcode(15 downto 12)="0000" AND opcode(8)='1' AND opcode(5 downto 3)="001") AND
	                       NOT (opcode(15 downto 11)="11101" AND opcode(7 downto 6)="11") AND
	                       opcode(15 downto 6)/="0100101011" AND
	                       NOT (opcode(15 downto 11)="00001" AND opcode(10 downto 9)/="00" AND opcode(8 downto 6)="011") AND
	                       micro_state/=trap00 AND micro_state/=trap0 AND micro_state/=trap1 AND micro_state/=trap2 AND
	                       micro_state/=trap4 AND micro_state/=trap5 AND micro_state/=trap6 AND
	                       micro_state/=ae_push AND interrupt='0' ELSE '0';
	acc_go <= '1' WHEN (acc_fpend='1' OR acc_wpend='1') AND decodeOPC='1' ELSE '0';
	acc_late <= '1' WHEN acc_fpend='1' AND decodeOPC='0' AND interrupt='0' ELSE '0';
	acc_restart <= '1' WHEN (acc_now='1' AND state/="00" AND acc_wdefer='0') OR acc_late='1' ELSE '0';
	xc_now <= ae_now OR acc_restart OR acc_go;

	nwr_l <= '1' WHEN ae_now='1' OR acc_fpend='1' OR (acc_wpend='1' AND state="11") ELSE
	       NOT fpu_bus_wr WHEN fpu_bus_act='1' ELSE
	       '0' WHEN m16_active='1' AND m16_step(3)='1' ELSE
	       '1' WHEN m16_active='1' ELSE
	       '0' WHEN state="11" ELSE '1';
	bus_l <= "11" WHEN fpu_bus_act='1' AND fpu_bus_wr='1' ELSE
	            "10" WHEN fpu_bus_act='1' ELSE
	            "11" WHEN m16_active='1' AND m16_step(3)='1' ELSE
	            "10" WHEN m16_active='1' ELSE
	            "01" WHEN ae_now='1' OR acc_fpend='1' OR (acc_wpend='1' AND state="11") ELSE state;
	addr_l <= fpu_bus_addr WHEN fpu_bus_act='1' ELSE m16_addr WHEN m16_active='1' ELSE addr_out_core;
	dwr_l <= fpu_bus_wdata WHEN fpu_bus_act='1' ELSE
	              m16_buf(conv_integer(m16_step(2 downto 0))) WHEN m16_active='1' AND m16_step(3)='1' ELSE data_write_core;
	nResetOut <= '0' WHEN exec(opcRESET)='1' ELSE '1';
	
	-- does shift for byte access. note active low me
	-- should produce address error on 68000
	memmaskmux <= memmask when addr(0) = '1' else memmask(4 downto 0) & '1';
	nuds_l <= fpu_uds_n WHEN fpu_bus_act='1' ELSE '0' WHEN m16_active='1' ELSE '1' WHEN ae_now='1' OR acc_fpend='1' OR (acc_wpend='1' AND state="11") ELSE memmaskmux(5);
	nlds_l <= fpu_lds_n WHEN fpu_bus_act='1' ELSE '0' WHEN m16_active='1' ELSE '1' WHEN ae_now='1' OR acc_fpend='1' OR (acc_wpend='1' AND state="11") ELSE memmaskmux(4);

	-- through the MMU: table search cycles, a held or quiet access, or the
	-- access at its physical address
	clkena_core <= clkena_in AND NOT mmu_stall;
	-- CPU space (FC 7, the interrupt acknowledge) is never translated (M68040 UM 3.1)
	-- nor a cycle the core marks with skipFetch (the dummy read of CLR, Scc and
	-- MOVE from SR, a skipped fetch), which MinimigAGA does not put on the bus
	mmu_act <= '1' WHEN bus_l/="01" AND cpu040='1' AND skipFetch_i='0' AND
	                    NOT (fc_int(1 downto 0)="11" AND fpu_bus_act='0' AND m16_active='0') ELSE '0';
	FC <= fc_int;
	skipFetch <= skipFetch_i AND NOT mmu_bact;
	mmu_fc <= SVmode & "10" WHEN bus_l="00" ELSE SVmode & "01";
	busstate <= "11" WHEN mmu_bact='1' AND mmu_bwr='1' ELSE
	            "10" WHEN mmu_bact='1' ELSE
	            "01" WHEN mmu_stall='1' OR mmu_quiet='1' ELSE bus_l;
	nWr <= NOT mmu_bwr WHEN mmu_bact='1' ELSE '1' WHEN mmu_stall='1' OR mmu_quiet='1' ELSE nwr_l;
	nUDS <= '0' WHEN mmu_bact='1' ELSE '1' WHEN mmu_stall='1' OR mmu_quiet='1' ELSE nuds_l;
	nLDS <= '0' WHEN mmu_bact='1' ELSE '1' WHEN mmu_stall='1' OR mmu_quiet='1' ELSE nlds_l;
	addr_out <= mmu_baddr WHEN mmu_bact='1' ELSE mmu_paddr WHEN cpu040='1' ELSE addr_l;
	data_write <= mmu_bwdata WHEN mmu_bact='1' ELSE dwr_l;

	mmu : entity work.TG68K_MMU
		port map (clk => clk, reset => Reset, clkena => clkena_in, tc_e => TC040E, tc_p => TC040,
				  urp => URP, srp => SRP, itt0 => ITT0, itt1 => ITT1, dtt0 => DTT0, dtt1 => DTT1,
				  act => mmu_act, laddr => addr_l, wr => mmu_wr, fc => mmu_fc, paddr => mmu_paddr,
				  stall => mmu_stall, quiet => mmu_quiet, fault => mmu_fault,
				  bus_act => mmu_bact, bus_addr => mmu_baddr, bus_wr => mmu_bwr, bus_wdata => mmu_bwdata,
				  data_in => data_in, ptest => mmu_ptest, ptest_addr => mmu_ptest_addr,
				  ptest_fc => DFC, ptest_wr => mmu_ptest_wr, ptest_done => mmu_ptest_done, mmusr => mmu_mmusr,
				  pflush => mmu_pflush, pflush_all => mmu_pflush_all, pflush_page => mmu_pflush_page,
				  pflush_addr => mmu_ptest_addr, pflush_s => DFC(2));
	mmu_wr <= NOT nwr_l;
	mmu_ptest_addr <= regfile(8 + conv_integer(opcode(2 downto 0)));
	mmu_ptest_wr <= NOT opcode(5);		-- PTESTW
	mmu_ptest <= '1' WHEN micro_state=mmu_ptest1 ELSE '0';
	-- a state after the decode, once the write of a MOVEC to DFC before it has landed
	mmu_pflush <= '1' WHEN micro_state=pflush1 ELSE '0';
	mmu_pflush_all <= opcode(3);		-- PFLUSHA, PFLUSH (An); PFLUSHAN and PFLUSHN keep global entries
	mmu_pflush_page <= NOT opcode(4);	-- PFLUSH (An), PFLUSHN (An): the page of An, S from DFC

	-- a translation fault is reported as a bus error at the end of the instruction
	process (clk)
	begin
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				mmu_fault_pend <= '0';
			ELSIF mmu_fault='1' AND clkena_in='1' AND cpu040='0' THEN
				mmu_fault_pend <= '1';
			ELSIF trap_berr='1' THEN
				mmu_fault_pend <= '0';
			END IF;
		END IF;
	END PROCESS;
	clkena_lw <= '1' WHEN clkena_core='1' AND (memmaskmux(3)='1' OR xc_now='1' OR long_fast='1') ELSE '0';
	clr_berr <= '1' WHEN setopcode='1' AND trap_berr='1' ELSE '0';
	
	PROCESS (clk, nReset)
	BEGIN
		IF nReset='0' THEN
			syncReset <= "0000";
			Reset <= '1'; 
	  	ELSIF rising_edge(clk) THEN
			IF clkena_core='1' THEN
				syncReset <= syncReset(2 downto 0)&'1';
				Reset <= NOT syncReset(3);	
			END IF;
		END IF;
		IF rising_edge(clk) THEN
			IF VBR_Stackframe=1 or (cpu010='1' and VBR_Stackframe=2) THEN
				use_VBR_Stackframe<='1';
			ELSE
				use_VBR_Stackframe<='0';
			END IF;
		END IF;
	END PROCESS;
			
PROCESS (clk, long_done, last_data_in, data_in, addr, long_start, memmaskmux, memread, memmask, data_read_w, long_fast, long_spec, data_in_lo)
	BEGIN
		IF memmaskmux(4)='0' THEN
			data_read_w <= last_data_in(15 downto 0)&data_in;
		ELSE
			data_read_w <= last_data_in(23 downto 0)&data_in(15 downto 8);
		END IF;
		IF memread(0)='1' OR (memread(1 downto 0)="10" AND memmaskmux(4)='1')THEN
			data_read_w(31 downto 16) <= (OTHERS=>data_read_w(15));
		END IF;	
		IF long_spec='1' THEN
			data_read <= data_in & data_in_lo;		-- the whole long at once
		ELSE
			data_read <= data_read_w;
		END IF;
		
		IF rising_edge(clk) THEN	
			IF clkena_lw='1' AND state="10" THEN
				IF memmaskmux(4)='0' THEN
					bf_ext_in <= last_data_in(23 downto 16);
				ELSE
					bf_ext_in <= last_data_in(31 downto 24);
				END IF;
			END IF;	
			IF Reset='1' THEN
				last_data_read <= (OTHERS => '0');
			ELSIF clkena_core='1' THEN
				IF state="00" OR exec(update_ld)='1' THEN 
					IF long_fast='1' THEN
						-- (a long in one cycle is not a word: memread has not advanced)
						last_data_read <= data_in & data_in_lo;
					ELSE
						last_data_read <= data_read_w;
						IF state(1)='0' AND memmask(1)='0' THEN
							last_data_read(31 downto 16) <= last_opc_read;
						ELSIF state(1)='0' OR memread(1)='1' THEN
							last_data_read(31 downto 16) <= (OTHERS=>data_in(15));
						END IF;
					END IF;
				END IF;
				IF long_fast='1' THEN
					last_data_in <= data_in & data_in_lo;
				ELSE
					last_data_in <= last_data_in(15 downto 0)&data_in(15 downto 0);
				END IF;
				
			END IF;
		END IF;
				long_start <= to_bit(NOT memmask(1));
				long_done <= to_bit(NOT memread(1));
	END PROCESS;
	
PROCESS (long_start, reg_QB, data_write_tmp, exec, data_read, data_write_mux, memmaskmux, bf_ext_out, long_fast, 
		 data_write_muxin, memmask, oddout, addr)
	BEGIN
		IF exec(write_reg)='1' THEN
			data_write_muxin <= reg_QB;
		ELSE
			data_write_muxin <= data_write_tmp;
		END IF;
		
		IF BitField=0 THEN
			IF oddout=addr(0) THEN
				data_write_mux <= "--------"&"--------"&data_write_muxin;
			ELSE
				data_write_mux <= "--------"&data_write_muxin&"--------";
			END IF;
		ELSE
			IF oddout=addr(0) THEN
				data_write_mux <= "--------"&bf_ext_out&data_write_muxin;
			ELSE
				data_write_mux <= bf_ext_out&data_write_muxin&"--------";
			END IF;
		END IF;
		
		IF memmaskmux(1)='0' THEN
			data_write_core <= data_write_mux(47 downto 32);
		ELSIF memmaskmux(3)='0' THEN	
			data_write_core <= data_write_mux(31 downto 16);
		ELSE
-- a single byte shows up on both bus halfs
			IF memmaskmux(5 downto 4) = "10" THEN
				data_write_core <= data_write_mux(7 downto 0) & data_write_mux(7 downto 0);
			ELSIF memmaskmux(5 downto 4) = "01" THEN
				data_write_core <= data_write_mux(15 downto 8) & data_write_mux(15 downto 8);
			ELSE
				data_write_core <= data_write_mux(15 downto 0);
			END IF;
		END IF;
		IF exec(mem_byte)='1' THEN	--movep
			data_write_core <= data_write_tmp(15 downto 8) & data_write_tmp(15 downto 8);
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- Registerfile
-----------------------------------------------------------------------------
PROCESS (clk, regfile, RDindex_A, RDindex_B, exec, m16_last, m16_inc_x, m16_inc_y, m16_rx, m16_ry, ae_fix_r, ae_fix_idx_r, ae_fix_val_r, micro_state,
		 fpu_wr_en, fpu_wr_size, fpu_wr_idx, fpu_wr_data, exec_chgM, chgM_S, OSP, USP, brief, preMmode)
	BEGIN
		reg_QA <= regfile(RDindex_A);
		reg_QB <= regfile(RDindex_B);
		IF rising_edge(clk) THEN
		    IF clkena_lw='1' THEN
				rf_source_addrd <= rf_source_addr;
				WR_AReg <= rf_dest_addr(3);
				RDindex_A <= conv_integer(rf_dest_addr(3 downto 0));
				RDindex_B <= conv_integer(rf_source_addr(3 downto 0));
				IF Wwrena='1' THEN
					regfile(RDindex_A) <= regin;
				END IF;
				IF micro_state=rte_ferr0 THEN
					sp_adj <= regfile(15) - 8;			-- the frame stays on the stack
				ELSIF micro_state=rte_f7 THEN
					sp_adj <= regfile(15) + 52;			-- the rest of a format $7 frame
				END IF;
				IF micro_state=rte_ferr OR micro_state=rte_f7b THEN
					regfile(15) <= sp_adj;
				END IF;
				m16_ax <= regfile(m16_rx) + 16;
				m16_ay <= regfile(m16_ry) + 16;
				IF ae_fix_r='1' AND micro_state=ae_fix1 AND acc_frame='0' THEN
					regfile(ae_fix_idx_r) <= ae_fix_val_r;
				END IF;
				IF fpu_wr_en='1' THEN
					CASE fpu_wr_size IS
						WHEN "00" => regfile(fpu_wr_idx)(7 downto 0) <= fpu_wr_data(7 downto 0);
						WHEN "01" => regfile(fpu_wr_idx)(15 downto 0) <= fpu_wr_data(15 downto 0);
						WHEN OTHERS => regfile(fpu_wr_idx) <= fpu_wr_data;
					END CASE;
				END IF;
				IF m16_last='1' THEN
					IF m16_inc_x='1' THEN
						regfile(m16_rx) <= m16_ax;
					END IF;
					IF m16_inc_y='1' AND (m16_inc_x='0' OR m16_ry/=m16_rx) THEN
						regfile(m16_ry) <= m16_ay;
					END IF;
				END IF;
				
				IF exec(to_USP)='1' THEN
					USP <= reg_QA;
				END IF;	
				-- SR.M changed: in supervisor mode A7 and OSP are swapped, in user
				-- mode USP and OSP; with S changing too, the M swap comes first, in
				-- the old mode, and changeMode then swaps A7 and USP
				IF exec_chgM='1' THEN
					IF chgM_S='1' THEN
						OSP <= reg_QA;
					ELSE
						OSP <= USP;
					END IF;
					IF chgM_S=to_stdulogic(exec(changeMode)) THEN
						USP <= OSP;
					END IF;
				END IF;
				-- MOVEC to the MSP or the ISP: A7 when M selects it, else OSP
				IF exec(movec_wr)='1' AND (brief(11 downto 0)=X"803" OR brief(11 downto 0)=X"804") THEN
					IF brief(0)=preMmode THEN
						regfile(15) <= reg_QA;
					ELSE
						OSP <= reg_QA;
					END IF;
				END IF;
				-- the registers as they were before the instruction: taken on its
				-- decode edge, with the write-back of the previous instruction
				-- landing on that edge merged in; an access error puts them back
				FOR i IN 0 TO 15 LOOP
					IF decodeOPC='1' THEN
						IF Wwrena='1' AND RDindex_A=i THEN
							rf_shadow(i) <= regin;
						ELSE
							rf_shadow(i) <= regfile(i);
						END IF;
					END IF;
					-- (on the decode edge itself only the write-back of the previous
					-- instruction lands, which stays)
					IF acc_restart='1' AND decodeOPC='0' THEN
						regfile(i) <= rf_shadow(i);
					END IF;
				END LOOP;
			END IF;
		END IF;
	END PROCESS;

-----------------------------------------------------------------------------
-- Write Reg
-----------------------------------------------------------------------------
PROCESS (OP1in, reg_QA, Regwrena_now, Bwrena, Lwrena, exe_datatype, WR_AReg, movem_actiond, exec, ALUout, memaddr, memaddr_a, ea_only, USP, movec_data,
		 exec_chgM, chgM_S, OSP)
	BEGIN
		regin <= ALUout;
		IF exec(save_memaddr)='1' THEN
			regin <= memaddr;	
		ELSIF exec(get_ea_now)='1' AND ea_only='1' THEN
			regin <= memaddr_a;	
		ELSIF exec_chgM='1' AND chgM_S/=to_stdulogic(exec(changeMode)) THEN
			regin <= OSP;		-- the other supervisor stack into A7
		ELSIF exec(from_USP)='1' THEN
			regin <= USP;	
		ELSIF exec(movec_rd)='1' THEN
			regin <= movec_data;
		END IF;
		
		IF Bwrena='1' THEN
			regin(15 downto 8) <= reg_QA(15 downto 8);
		END IF;
		IF Lwrena='0' THEN
			regin(31 downto 16) <= reg_QA(31 downto 16);
		END IF;

		Bwrena <= '0';
		Wwrena <= '0';
		Lwrena <= '0';
		IF exec(presub)='1' OR exec(postadd)='1' OR exec(changeMode)='1' OR (exec_chgM='1' AND chgM_S='1') THEN		-- -(An)+
			Wwrena <= '1';
			Lwrena <= '1';
		ELSIF Regwrena_now='1' THEN		--dbcc	
			Wwrena <= '1';
		ELSIF exec(Regwrena)='1' THEN		--read (mem)
			Wwrena <= '1';
			CASE exe_datatype IS
				WHEN "00" =>		--BYTE
					Bwrena <= '1';
				WHEN "01" =>		--WORD
					IF WR_AReg='1' OR movem_actiond='1' THEN
						Lwrena <='1';
					END IF;
				WHEN OTHERS =>		--LONG
					Lwrena <= '1';
			END CASE;
		END IF;	
	END PROCESS;
	
-----------------------------------------------------------------------------
-- set dest regaddr
-----------------------------------------------------------------------------
PROCESS (opcode, rf_source_addrd, brief, setstackaddr, dest_hbits, dest_areg, dest_LDRareg, data_is_source, sndOPC, exec, set, dest_2ndHbits, dest_2ndLbits, dest_LDRHbits, dest_LDRLbits, last_data_read, ae_now, xc_now, preSVmode)
	BEGIN
		IF exec(movem_action) ='1' THEN
			rf_dest_addr <= rf_source_addrd;
		ELSIF set(briefext)='1' THEN
			rf_dest_addr <= brief(15 downto 12);
		ELSIF set(get_bfoffset)='1' THEN
--			IF opcode(15 downto 12)="1110" THEN
				rf_dest_addr <= '0'&sndOPC(8 downto 6);
--			ELSE
--				rf_dest_addr <= sndOPC(9 downto 6);
--			END IF;
		ELSIF dest_2ndHbits='1' THEN
			rf_dest_addr <= dest_LDRareg&sndOPC(14 downto 12);
		ELSIF dest_LDRHbits='1' THEN
			rf_dest_addr <= last_data_read(15 downto 12);
		ELSIF dest_LDRLbits='1' THEN
			rf_dest_addr <= '0'&last_data_read(2 downto 0);
		ELSIF dest_2ndLbits='1' THEN
			rf_dest_addr <= '0'&sndOPC(2 downto 0);
		ELSIF setstackaddr='1' THEN	
			rf_dest_addr <= "1111";
		ELSIF dest_hbits='1' THEN	
			rf_dest_addr <= dest_areg&opcode(11 downto 9);
		ELSE
			IF opcode(5 downto 3)="000" OR data_is_source='1' THEN 			
				rf_dest_addr <= dest_areg&opcode(2 downto 0);
			ELSE
				rf_dest_addr <= '1'&opcode(2 downto 0);
			END IF;
		END IF;	
			IF xc_now='1' AND preSVmode='0' THEN
			rf_dest_addr <= "1111";		-- address error from user mode: A7 for the swap
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- set source regaddr
-----------------------------------------------------------------------------
PROCESS (opcode, movem_presub, movem_regaddr, source_lowbits, source_areg, sndOPC, exec, set, source_2ndLbits, source_2ndHbits, 	source_LDRLbits, source_LDRMbits, last_data_read, source_2ndMbits)
	BEGIN
		IF exec(movem_action)='1' OR set(movem_action) ='1' THEN
			IF movem_presub='1' THEN
				rf_source_addr <= movem_regaddr XOR "1111";
			ELSE
				rf_source_addr <= movem_regaddr;
			END IF; 
		ELSIF source_2ndLbits='1' THEN
			rf_source_addr <= '0'&sndOPC(2 downto 0);
		ELSIF source_2ndHbits='1' THEN
			rf_source_addr <= '0'&sndOPC(14 downto 12);
		ELSIF source_2ndMbits='1' THEN
			rf_source_addr <= '0'&sndOPC(8 downto 6);
		ELSIF source_LDRLbits='1' THEN
			rf_source_addr <= '0'&last_data_read(2 downto 0);
		ELSIF source_LDRMbits='1' THEN
			rf_source_addr <= '0'&last_data_read(8 downto 6);
		ELSIF source_lowbits='1' THEN
			rf_source_addr <= source_areg&opcode(2 downto 0);
		ELSIF exec(linksp)='1' THEN
			rf_source_addr <= "1111";
		ELSE
			rf_source_addr <= source_areg&opcode(11 downto 9);
		END IF;	
	END PROCESS;
	
-----------------------------------------------------------------------------
-- set OP1out
-----------------------------------------------------------------------------
PROCESS (reg_QA, store_in_tmp, ea_data, long_start, addr, exec, memmaskmux, long_spec)
	BEGIN
		OP1out <= reg_QA;
		IF exec(OP1out_zero)='1' THEN
			OP1out <= (OTHERS => '0');	
		ELSIF exec(ea_data_OP1)='1' AND store_in_tmp='1' THEN
			OP1out <= ea_data;
		ELSIF exec(movem_action)='1' OR (memmaskmux(3)='0' AND long_spec='0') OR exec(OP1addr)='1' THEN 
			OP1out <= addr;
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- set OP2out
-----------------------------------------------------------------------------
PROCESS (OP2out, reg_QB, exe_opcode, exe_datatype, execOPC, exec, use_direct_data, 
	     store_in_tmp, data_write_tmp, ea_data)
	BEGIN
		OP2out(15 downto 0) <= reg_QB(15 downto 0);
		OP2out(31 downto 16) <= (OTHERS => OP2out(15));
		IF exec(OP2out_one)='1' THEN
			OP2out(15 downto 0) <= "1111111111111111";
		ELSIF use_direct_data='1' OR (exec(exg)='1' AND execOPC='1') OR exec(get_bfoffset)='1' THEN	
			OP2out <= data_write_tmp;	
		ELSIF (exec(ea_data_OP1)='0' AND store_in_tmp='1') OR exec(ea_data_OP2)='1' THEN
			OP2out <= ea_data;	
		ELSIF exec(opcMOVEQ)='1' THEN
			OP2out(7 downto 0) <= exe_opcode(7 downto 0);
			OP2out(15 downto 8) <= (OTHERS => exe_opcode(7));
		ELSIF exec(opcADDQ)='1' THEN
			OP2out(2 downto 0) <= exe_opcode(11 downto 9);
			IF exe_opcode(11 downto 9)="000" THEN
				OP2out(3) <='1';
			ELSE
				OP2out(3) <='0';
			END IF;
			OP2out(15 downto 4) <= (OTHERS => '0');
		ELSIF exe_datatype="10" AND exec(opcEXT)='0'  THEN 
			OP2out(31 downto 16) <= reg_QB(31 downto 16);
		END IF;
		IF exec(opcEXTB)='1' THEN
			OP2out(31 downto 8) <= (OTHERS => OP2out(7));		
		END IF;
	END PROCESS;
	

-----------------------------------------------------------------------------
-- handle EA_data, data_write
-----------------------------------------------------------------------------
PROCESS (clk)
	BEGIN
     	IF rising_edge(clk) THEN
			IF Reset = '1' THEN
				store_in_tmp <='0';
				direct_data <= '0';
				use_direct_data <= '0';
				Z_error <= '0';
				writePCnext <= '0';
			ELSIF clkena_lw='1' THEN
				useStackframe2<='0';
				direct_data <= '0';
				IF exec(hold_OP2)='1' THEN
					use_direct_data <= '1';
				END IF;
				IF set_direct_data='1' THEN
					direct_data <= '1';
					use_direct_data <= '1';
				ELSIF endOPC='1' OR set(ea_data_OP2)='1' THEN	
					use_direct_data <= '0';
				END IF;	
				exec_DIRECT <= set_exec(opcMOVE);
				
				IF endOPC='1' THEN
					store_in_tmp <='0';
					Z_error <= '0';
					writePCnext <= '0';
				ELSE
					IF set_Z_error='1'  THEN
						Z_error <= '1';
					END IF;	
					IF set_exec(opcMOVE)='1' AND state="11" THEN
						use_direct_data <= '1';
					END IF;

					IF state="10" OR exec(store_ea_packdata)='1' THEN
						store_in_tmp <= '1'; 
					END IF;
					IF direct_data='1' AND state="00" THEN
						store_in_tmp <= '1'; 
					END IF;	
				END IF;
				
				IF state="10" AND exec(hold_ea_data)='0' THEN
					ea_data <= data_read;
				ELSIF exec(get_2ndOPC)='1' THEN
					ea_data <= addr;
				ELSIF exec(store_ea_data)='1' OR (direct_data='1' AND state="00") THEN
					ea_data <= last_data_read;
				END IF;	
				
				IF fr_sel='1' THEN
					-- a word of an address or access error frame (fr_word)
					IF fr_lo='1' THEN
						data_write_tmp(15 downto 0) <= fr_word(15 downto 0);
					ELSE
						data_write_tmp <= fr_word;
					END IF;
					IF fr_sf2='1' THEN
						useStackframe2 <= '1';
					END IF;
				ELSIF micro_state=link1 AND opcode(2 downto 0)="111" THEN
					-- LINK A7: SP - 4 -> SP; An -> (SP), so the pushed value is the
					-- decremented SP (M68000 PRM, LINK); the predecrement is being
					-- written to A7 on this edge
					-- (that write is A7 - 4: taken from the register, not from regin,
					-- which would put the ALU on the path to data_write_tmp)
					IF Wwrena='1' AND RDindex_A=15 THEN
						data_write_tmp <= regfile(15) - 4;
					ELSE
						data_write_tmp <= regfile(15);
					END IF;
				ELSIF writePC='1' THEN
					data_write_tmp <= TG68_PC;
				ELSIF (fmt_err='1' OR fpu_lf='1' OR fpu_tx='1') AND micro_state=trap1 THEN
					data_write_tmp <= exe_pc;			-- format error: the RTE; FP pre-instruction
				ELSIF (fpu_tf='1' OR fpu_tfp='1' OR fpu_tu='1') AND micro_state=trap1 THEN
					data_write_tmp <= fpu_next_pc;		-- unimplemented FP, FTRAPcc: the next instruction
				ELSIF exec(writePC_add)='1' THEN
					data_write_tmp <= TG68_PC_add;
-- paste and copy form TH	---------	
				elsif micro_state=trap00 AND (fpu_tf='1' OR fpu_tu='1') THEN
					data_write_tmp <= fpu_ea_out;		-- unimplemented FP: the <ea>
					useStackframe2<='1';
					writePCnext <= '0';
				elsif micro_state=trap00 THEN
					data_write_tmp <= exe_pc; --TH
					useStackframe2<='1';
					writePCnext <= trap_trap OR trap_trapv OR exec(trap_chk) OR Z_error;
				elsif micro_state = trap0 then
		  -- this is only active for 010+ since in 000 writePC is
		  -- true in state trap0
--					if trap_trace='1' or set_exec(opcTRAPV)='1' or Z_error='1' then
					IF	useStackframe2='1' AND fpu_tu='1' THEN
						-- FMOVE.P out: format $3, the effective address (68040 UM 9.6.2)
						data_write_tmp(15 downto 0) <= "0011" & trap_vector(11 downto 0);
					ELSIF	useStackframe2='1' THEN
						-- stack frame format #2
						data_write_tmp(15 downto 0) <= "0010" & trap_vector(11 downto 0); --TH
					elsif thr_pass='1' then
						data_write_tmp(15 downto 0) <= "0001" & trap_vector(11 downto 0);	-- throwaway
					else
						data_write_tmp(15 downto 0) <= "0000" & trap_vector(11 downto 0);
						writePCnext <= trap_trap OR trap_trapv OR exec(trap_chk) OR Z_error;
					end if;
------------------------------------
--				ELSIF micro_state=trap0 THEN	
--					data_write_tmp(15 downto 0) <= trap_vector(15 downto 0);
				ELSIF exec(hold_dwr)='1' THEN	
					data_write_tmp <= data_write_tmp;
				ELSIF exec(exg)='1' THEN	
					data_write_tmp <= OP1out;
				ELSIF exec(get_ea_now)='1' AND ea_only='1' THEN		-- ist for pea
					data_write_tmp <= addr;
				ELSIF execOPC='1' THEN
					data_write_tmp <= ALUout;
				ELSIF (exec_DIRECT='1' AND state="10") THEN
					data_write_tmp <= data_read;
					IF  exec(movepl)='1' THEN
						data_write_tmp(31 downto 8) <= data_write_tmp(23 downto 0);
					END IF;
				ELSIF exec(movepl)='1' THEN
					data_write_tmp(15 downto 0) <= reg_QB(31 downto 16);
				ELSIF direct_data='1' THEN
					data_write_tmp <= last_data_read;
				ELSIF writeSR='1'THEN
					data_write_tmp(15 downto 0) <= trap_SR(7 downto 0)& Flags(7 downto 0);
				ELSE	
					data_write_tmp <= OP2out;
				END IF;
			END IF;	
		END IF;	
	END PROCESS;
	
-----------------------------------------------------------------------------
-- brief
-----------------------------------------------------------------------------
PROCESS (brief, OP1out, OP1outbrief, cpu)
	BEGIN
		IF brief(11)='1' THEN
			OP1outbrief <= OP1out(31 downto 16);
		ELSE
			OP1outbrief <= (OTHERS=>OP1out(15));
		END IF;
		briefdata <= OP1outbrief&OP1out(15 downto 0);
		IF extAddr_Mode=1 OR (cpu(1)='1' AND extAddr_Mode=2) THEN
			CASE brief(10 downto 9) IS
				WHEN "00" => briefdata <= OP1outbrief&OP1out(15 downto 0);
				WHEN "01" => briefdata <= OP1outbrief(14 downto 0)&OP1out(15 downto 0)&'0';
				WHEN "10" => briefdata <= OP1outbrief(13 downto 0)&OP1out(15 downto 0)&"00";
				WHEN "11" => briefdata <= OP1outbrief(12 downto 0)&OP1out(15 downto 0)&"000";
				WHEN OTHERS => NULL;
			END CASE;
		END IF;
	END PROCESS;

-----------------------------------------------------------------------------
-- MEM_IO 
-----------------------------------------------------------------------------
PROCESS (clk, setdisp, memaddr_a, briefdata, memaddr_delta, setdispbyte, datatype, interrupt, rIPL_nr, IPL_vec,
         memaddr_reg, memaddr_delta_rega, memaddr_delta_regb, reg_QA, use_base, VBR, last_data_read, trap_vector, exec, set, cpu, use_VBR_Stackframe)
	BEGIN
		
		IF rising_edge(clk) THEN
			IF clkena_lw='1' THEN
				trap_vector(31 downto 10) <= (others => '0');
				IF trap_berr='1' THEN
					trap_vector(9 downto 0) <= "00" & X"08";
				END IF;	
				IF trap_addr_error='1' THEN
					trap_vector(9 downto 0) <= "00" & X"0C";
				END IF;	
				IF trap_illegal='1' THEN
					trap_vector(9 downto 0) <= "00" & X"10";
				END IF;	
				IF set_Z_error='1' THEN
					trap_vector(9 downto 0) <= "00" & X"14";
				END IF;	
				IF exec(trap_chk)='1' AND decodeOPC='0' THEN	-- not a stale CHK, see trap00
					trap_vector(9 downto 0) <= "00" & X"18";
				END IF;	
				IF trap_trapv='1' THEN
					trap_vector(9 downto 0) <= "00" & X"1C";
				END IF;	
				IF trap_priv='1' THEN
					trap_vector(9 downto 0) <= "00" & X"20";
				END IF;	
				IF trap_trace='1' THEN
					trap_vector(9 downto 0) <= "00" & X"24";
				END IF;	
				IF trap_1010='1' THEN
					trap_vector(9 downto 0) <= "00" & X"28";
				END IF;	
				IF trap_1111='1' THEN
					trap_vector(9 downto 0) <= "00" & X"2C";
				END IF;	
				IF trap_fmt='1' THEN
					trap_vector(9 downto 0) <= "00" & X"38";		-- format error
				END IF;
				IF trap_fpx='1' THEN
					trap_vector(9 downto 0) <= "00" & "110" & fpx_v & "00";		-- 48 + n
				END IF;
				IF trap_unsupp='1' THEN
					trap_vector(9 downto 0) <= "00" & X"DC";		-- FP unsupported data type
				END IF;
				IF trap_trap='1' THEN
					trap_vector(9 downto 0) <= "0010" & opcode(3 downto 0) & "00";
				END IF;	
				IF trap_interrupt='1' or set_vectoraddr = '1' THEN
					trap_vector(9 downto 0) <= IPL_vec & "00";      --TH
				END IF;	
				IF ae_now='1' THEN		-- address error, over anything else this cycle
					trap_vector(9 downto 0) <= "00" & X"0C";
				END IF;
				IF acc_restart='1' OR acc_go='1' THEN		-- access error
					trap_vector(9 downto 0) <= "00" & X"08";
				END IF;
			END IF;
		END IF;
		IF use_VBR_Stackframe='1' THEN
			trap_vector_vbr <= trap_vector+VBR;
		ELSE		
			trap_vector_vbr <= trap_vector;
		END IF;		
		
		memaddr_a(4 downto 0) <= "00000";
		memaddr_a(7 downto 5) <= (OTHERS=>memaddr_a(4));
		memaddr_a(15 downto 8) <= (OTHERS=>memaddr_a(7));
		memaddr_a(31 downto 16) <= (OTHERS=>memaddr_a(15));
		IF setdisp='1' THEN
			IF exec(briefext)='1' THEN
				memaddr_a <= briefdata+memaddr_delta;
			ELSIF setdispbyte='1' THEN
				memaddr_a(7 downto 0) <= last_data_read(7 downto 0);
			ELSE
				memaddr_a <= last_data_read;
			END IF;	 
		ELSIF set(presub)='1' THEN
			IF set(longaktion)='1' THEN	
				memaddr_a(4 downto 0) <= "11100";
			ELSIF datatype="00" AND set(use_SP)='0' THEN
				memaddr_a(4 downto 0) <= "11111";
			ELSE
				memaddr_a(4 downto 0) <= "11110";
			END IF;	
		ELSIF interrupt='1' THEN
			memaddr_a(4 downto 0) <= '1'&rIPL_nr&'0';	
		END IF;	 
		
		IF rising_edge(clk) THEN
			IF clkena_core='1' THEN
				IF exec(get_2ndOPC)='1' OR (state="10" AND memread(0)='1') THEN
					tmp_TG68_PC <= addr;
				END IF;
				use_base <= '0'; 
				memaddr_delta_regb <= (others => '0');
				IF (memmaskmux(3)='0' AND long_spec='0') OR exec(mem_addsub)='1' THEN
					memaddr_delta_rega <= addsub_q;
				ELSIF set(restore_ADDR)='1' THEN
					memaddr_delta_rega <= tmp_TG68_PC;
				ELSIF exec(direct_delta)='1' THEN
					memaddr_delta_rega <= data_read;
				ELSIF fpu_jump='1' THEN
					memaddr_delta_rega <= fpu_target;
				ELSIF exec(ea_to_pc)='1' AND setstate="00" THEN
					memaddr_delta_rega <= addr;
				ELSIF set(addrlong)='1' THEN
					memaddr_delta_rega <= last_data_read;
				ELSIF setstate="00" THEN
					memaddr_delta_rega <= TG68_PC_add;
				ELSIF exec(dispouter)='1' THEN
					memaddr_delta_rega <= ea_data;
					memaddr_delta_regb <= memaddr_a;
				ELSIF set_vectoraddr='1' THEN
					memaddr_delta_rega <= trap_vector_vbr;
				ELSE 
					memaddr_delta_rega <= memaddr_a;
					IF interrupt='0' AND Suppress_Base='0' THEN
--					IF interrupt='0' AND Suppress_Base='0' AND setstate(1)='1' THEN
						use_base <= '1';
					END IF;	
				END IF;
				-- a long asked for in one cycle but taken as two words: the
				-- next word, which the ALU would have given (addr + 2) had it
				-- not been working out the long
				IF memmaskmux(3)='0' AND long_spec='1' AND long_fast='0' THEN
					memaddr_delta_rega <= addr_p2;
					memaddr_delta_regb <= (others => '0');
					use_base <= '0';
				END IF;
					
		-- only used for movem address update
--					IF (long_done='0' AND state(1)='1') OR movem_presub='0' THEN
					if ((memread(0) = '1' or long_fast = '1') and state(1) = '1') or movem_presub = '0' then -- fix for unaligned movem mikej
						memaddr <= addr;
					END IF;
			END IF;
		END IF;

		memaddr_delta <= memaddr_delta_rega + memaddr_delta_regb;
		-- if access done, and not aligned, don't increment
		addr <= memaddr_reg+memaddr_delta;
		addr_out_core <= memaddr_reg + memaddr_delta;

		IF use_base='0' THEN
			memaddr_reg <= (others=>'0');
		ELSE	
			memaddr_reg <= reg_QA;
		END IF;	
    END PROCESS;
    
-----------------------------------------------------------------------------
-- PC Calc + fetch opcode
-----------------------------------------------------------------------------
PROCESS (clk, IPL, setstate, addrvalue, state, exec_write_back, set_direct_data, next_micro_state, stop, make_trace, make_berr, IPL_nr, nmi_pending, FlagsSR, set_rot_cnt, opcode, writePCbig, set_exec, exec,
        PC_dataa, PC_datab, setnextpass, last_data_read, TG68_PC_brw, TG68_PC_word, Z_error, trap_trap, trap_trapv, interrupt, tmp_TG68_PC, TG68_PC, use_VBR_Stackframe, writePCnext, ae_now, xc_now)
	BEGIN
	
		PC_dataa <= TG68_PC;
		IF TG68_PC_brw = '1' THEN
			PC_dataa <= tmp_TG68_PC;
		END IF;
		
		PC_datab(2 downto 0) <= (others => '0');
		PC_datab(3) <= PC_datab(2);
		PC_datab(7 downto 4) <= (others => PC_datab(3));
		PC_datab(15 downto 8) <= (others => PC_datab(7));
		PC_datab(31 downto 16) <= (others => PC_datab(15));
		IF interrupt='1' THEN
			PC_datab(2 downto 1) <= "11";
		END IF;
		IF exec(writePC_add) ='1' THEN
			IF writePCbig='1' THEN
				PC_datab(3) <= '1';
				PC_datab(1) <= '1';
			ELSE	
				PC_datab(2) <= '1';
			END IF;
			IF (use_VBR_Stackframe='0' AND (trap_trap='1' OR trap_trapv='1' OR exec(trap_chk)='1' OR Z_error='1')) OR writePCnext='1' THEN
				PC_datab(1) <= '1';
			END IF;
		ELSIF state="00" THEN
			PC_datab(1) <= '1';
		END IF;	
		IF TG68_PC_brw = '1' THEN	
			IF TG68_PC_word='1' THEN
				PC_datab <= last_data_read;
			ELSE
				PC_datab(7 downto 0) <= opcode(7 downto 0);
			END IF;
		END IF;

		TG68_PC_add <= PC_dataa+PC_datab;
		
		setopcode <= '0';
		setendOPC <= '0';
		setinterrupt <= '0';
		IF setstate="00" AND next_micro_state=idle AND setnextpass='0' AND (exec_write_back='0' OR state="11") AND set_rot_cnt="000001" AND set_exec(opcCHK)='0'THEN
			setendOPC <= '1';
			-- level 7 passes the mask only on its rising edge (nmi_pending)
			IF acc_wpend='0' AND (FlagsSR(2 downto 0)<IPL_nr OR (IPL_nr="111" AND nmi_pending='1') OR make_trace='1' OR make_berr='1') THEN
				setinterrupt <= '1';
			ELSIF stop='0' THEN
				setopcode <= '1';
			END IF;
		END IF;	
		setexecOPC <= '0';
		IF setstate="00" AND next_micro_state=idle AND set_direct_data='0' AND (exec_write_back='0' OR (state="10" AND addrvalue='0')) THEN
			setexecOPC <= '1';
		END IF;
		IF xc_now='1' THEN
			-- an address error ends the instruction here: no next opcode
			setendOPC <= '0';
			setopcode <= '0';
			setinterrupt <= '0';
			setexecOPC <= '0';
		END IF;
		
		IPL_nr <= NOT IPL;
		IF rising_edge(clk) THEN
			IF Reset = '1' THEN
				state <= "01";
				addrvalue <= '0';
				opcode <= X"2E79"; 					--move $0,a7
				trap_interrupt <= '0';
				interrupt <= '0';
				last_opc_read  <= X"4EF9";			--jmp nn.l
				TG68_PC <= X"00000004";
				decodeOPC <= '0';
				endOPC <= '0';
				TG68_PC_word <= '0';
				execOPC <= '0';
--				execOPC_ALU <= '0';
				stop <= '0';
				rot_cnt <="000001";
--				byte <= '0';
--				IPL_nr <= "000";
				trap_trace <= '0';
				trap_berr <= '0';
				writePCbig <= '0';
--				recall_last <= '0';
				Suppress_Base <= '0'; 
				make_berr <= '0';
				memmask <= "111111";
				exec_write_back <= '0';
			ELSE
--				IPL_nr <= NOT IPL;
				IF clkena_core='1' THEN
					memmask <= memmask(3 downto 0)&"11";
					memread <= memread(1 downto 0)&memmaskmux(5 downto 4);
--					IF wbmemmask(5 downto 4)="11" THEN	
--						wbmemmask <= memmask;
--					END IF;
					IF exec(directPC)='1' THEN
						TG68_PC <= data_read;
					ELSIF fpu_jump='1' THEN
						TG68_PC <= fpu_target;
					ELSIF exec(ea_to_pc)='1' THEN
						TG68_PC <= addr;
					ELSIF (state ="00" OR TG68_PC_brw = '1') AND stop='0'  THEN				
						TG68_PC <= TG68_PC_add;
					END IF;	
				END IF;	
				IF clkena_lw='1' THEN
					interrupt <= setinterrupt;
					decodeOPC <= setopcode;
					endOPC <= setendOPC;
					execOPC <= setexecOPC;
--					IF setexecOPC='1' OR set(alu_exec)='1' THEN
--						execOPC_ALU <= '1';
--					ELSE
--						execOPC_ALU <= '0';
--					END IF;
					
					exe_datatype <= set_datatype;
					exe_opcode <= opcode;

					if(trap_berr='0') then
						make_berr <= ((berr AND NOT cpu040) OR mmu_fault_pend OR make_berr);	-- 68040: TEA
					else
						make_berr <= '0';
					end if;
						
					stop <= set_stop OR (stop AND NOT setinterrupt);
					IF setinterrupt='1' THEN
						trap_interrupt <= '0';
						trap_trace <= '0';
--						TG68_PC_word <= '0';
						make_berr <= '0';
						trap_berr <= '0';
						IF make_trace='1' THEN
							trap_trace <= '1';
						ELSIF make_berr='1' THEN
							trap_berr <= '1';
						ELSE	
							rIPL_nr <= IPL_nr;
							IPL_vec <= "00011"&IPL_nr;            --	TH		
							trap_interrupt <= '1';
						END IF;
					END IF;	
					IF micro_state=trap0 AND IPL_autovector='0' AND thr_pass='0' THEN 			
						IPL_vec <= last_data_read(7 downto 0);    --	TH
					END IF;	
					IF state="00" THEN				
						last_opc_read <= data_read(15 downto 0);
						last_opc_pc <= tg68_pc;--TH
					END IF;	
					IF setopcode='1' THEN
						trap_interrupt <= '0';
						trap_trace <= '0';
						TG68_PC_word <= '0';
						trap_berr <= '0';
					-- a displacement byte of $FF selects the 32-bit form only on the
					-- 68020 and later; on the 68000 and 68010 it is -1 (PRM, Bcc)
					ELSIF opcode(7 downto 0)="00000000" OR (opcode(7 downto 0)="11111111" AND cpu(1)='1') OR data_is_source='1' OR fpu_fbcc='1' THEN
						TG68_PC_word <= '1';
					END IF;	
					
					IF exec(get_bfoffset)='1' THEN
						alu_width <= bf_width;
						alu_bf_shift <= bf_shift;
						alu_bf_loffset <= bf_loffset;
						alu_bf_ffo_offset <= bf_full_offset+bf_width+1;
					END IF;
					memread <= "1111";
					fc_int(1) <= NOT setstate(1) OR (PCbase AND NOT setstate(0));
					fc_int(0) <= setstate(1) AND (NOT PCbase OR setstate(0));
					IF interrupt='1' THEN
						fc_int(1 downto 0) <= "11";
					END IF;	
					
					IF state="11" OR xc_now='1' THEN
						exec_write_back <= '0';			-- (an aborted read-modify-write too)
					ELSIF setstate="10" AND setaddrvalue='0' AND write_back='1' THEN
						exec_write_back <= '1';
					END IF;	
					IF (state="10" AND addrvalue='0' AND write_back='1' AND setstate/="10") OR set_rot_cnt/="000001" OR (stop='1' AND interrupt='0') OR set_exec(opcCHK)='1' THEN
						state <= "01";
						memmask <= "111111";
						addrvalue <= '0';
					ELSIF execOPC='1' AND exec_write_back='1' THEN
						state <= "11";
						fc_int(1 downto 0) <= "01";
						memmask <= wbmemmask;
						addrvalue <= '0';
					ELSIF xc_now='1' THEN
						state <= "01";
						memmask <= "111111";
						addrvalue <= '0';
					ELSE	
						state <= setstate;
						addrvalue <= setaddrvalue; 
						IF setstate="01" THEN
							memmask <= "111111";
							wbmemmask <= "111111";
						ELSIF exec(get_bfoffset)='1' THEN
							memmask <= set_memmask;
							wbmemmask <= set_memmask;
							oddout <= set_oddout;
						ELSIF set(longaktion)='1' THEN
							memmask <= "100001";
							wbmemmask <= "100001";
							oddout <= '0';
--						ELSIF set_datatype="00" AND setstate(1)='1' AND setaddrvalue='0' THEN	
						ELSIF set_datatype="00" AND setstate(1)='1' THEN	
							memmask <= "101111";
							wbmemmask <= "101111";
							IF set(mem_byte)='1' THEN
								oddout <= '0';
							ELSE
								oddout <= '1';
							END IF;	
						ELSE	
							memmask <= "100111";
							wbmemmask <= "100111";
							oddout <= '0';
						END IF;	
					END IF;

					IF decodeOPC='1' THEN
						rot_bits <= set_rot_bits;
						writePCbig <= '0';
					ELSE	
						writePCbig <= set_writePCbig OR writePCbig; 
					END IF;
					IF decodeOPC='1' OR exec(ld_rot_cnt)='1' OR rot_cnt/="000001" THEN
						rot_cnt <= set_rot_cnt;
					END IF;
					
					IF set_Suppress_Base='1' THEN
						Suppress_Base <= '1';
					ELSIF setstate(1)='1' OR (ea_only='1' AND set(get_ea_now)='1') THEN	
						Suppress_Base <= '0';
					END IF;
					IF getbrief='1' THEN
						IF state(1)='1' THEN
							brief <= last_opc_read(15 downto 0);
						ELSE
							brief <= data_read(15 downto 0);
						END IF;
					END IF;	
					
					IF xc_now='1' THEN
						-- an address error ends the instruction: as an interrupt does,
						-- a NOP stands in for its opcode during exception processing
						-- (ae_ir keeps the real one for the frame)
						opcode <= X"4E71";
						nextpass <= '0';
					ELSIF setopcode='1' AND berr='0' THEN
						IF state="00" THEN
							opcode <= data_read(15 downto 0);
							exe_pc <= tg68_pc;--TH
						ELSE
							opcode <= last_opc_read(15 downto 0);
							exe_pc <= last_opc_pc;--TH
						END IF;
						nextpass <= '0';
					ELSIF setinterrupt='1' OR setopcode='1' THEN
						opcode <= X"4E71";		--nop
						nextpass <= '0';
					ELSE
--						IF setnextpass='1' OR (regdirectsource='1' AND state="00") THEN
						IF setnextpass='1' OR regdirectsource='1' THEN
							nextpass <= '1';	
						END IF;
					END IF;

					IF decodeOPC='1' OR interrupt='1' THEN
						trap_SR <= FlagsSR;
					END IF;
					-- the SR before an RTE, for its format error: taken on the edge
					-- after the decode, once the previous instruction has written its
					-- flags and before the RTE loads the SR it reads
					IF exec(directSR)='1' THEN
						rte_sr <= FlagsSR;
						rte_ccr <= Flags;
					END IF;
					IF micro_state=rte_ferr THEN
						trap_SR <= rte_sr;
					END IF;
					IF micro_state=thr0 THEN
						trap_SR(5) <= '1';		-- the throwaway frame's SR has S set
					END IF;
				END IF;	
			END IF;	
		END IF;	
	
		IF rising_edge(clk) THEN
			IF Reset = '1' THEN
				PCbase <= '1';
			ELSIF clkena_lw='1' THEN
				PCbase <= set_PCbase OR PCbase;
				IF setexecOPC='1' OR (state(1)='1' AND movem_run='0') THEN
					PCbase <= '0';
				END IF;	
			END IF;	
			IF clkena_lw='1' THEN
				exec <= set;
				exec(alu_move) <= set(opcMOVE) OR set(alu_move);
				exec(alu_setFlags) <= set(opcADD) OR set(alu_setFlags);
				exec_tas <= '0';
				exec(subidx) <= set(presub) or set(subidx);
				IF setexecOPC='1' THEN
					exec <= set_exec OR set;
					exec(alu_move) <= set_exec(opcMOVE) OR set(opcMOVE) OR set(alu_move);
					exec(alu_setFlags) <= set_exec(opcADD) OR set(opcADD) OR set(alu_setFlags);
					exec_tas <= set_exec_tas;
				END IF;	
				exec(get_2ndOPC) <= set(get_2ndOPC) OR setopcode;
				IF xc_now='1' THEN
					exec <= (OTHERS => '0');	-- the aborted instruction does no more
					IF preSVmode='0' THEN
						-- from user mode: A7 and USP are swapped next, as changeMode does
						exec(changeMode) <= '1';
						exec(to_USP) <= '1';
						exec(from_USP) <= '1';
					END IF;
				END IF;
			END IF;	
		END IF;	
	END PROCESS;
	
------------------------------------------------------------------------------
--prepare Bitfield Parameters
------------------------------------------------------------------------------		
PROCESS (clk, Reset, sndOPC, reg_QA, reg_QB, bf_width, bf_offset, bf_bhits, opcode, setstate, bf_shift)
	BEGIN
		IF sndOPC(11)='1' THEN
			bf_offset <= '0'&reg_QA(4 downto 0);
		ELSE
			bf_offset <= '0'&sndOPC(10 downto 6);
		END IF;	
		IF sndOPC(11)='1' THEN
			bf_full_offset <= reg_QA;
		ELSE
			bf_full_offset <= (others => '0');
			bf_full_offset(4 downto 0) <= sndOPC(10 downto 6);
		END IF;	
		
		bf_width(5) <= '0';
		IF sndOPC(5)='1' THEN
			bf_width(4 downto 0) <= reg_QB(4 downto 0)-1;
		ELSE
			bf_width(4 downto 0) <= sndOPC(4 downto 0)-1;
		END IF;	
		bf_bhits <= bf_width+bf_offset;
		set_oddout <= NOT bf_bhits(3);
		

-- bf_loffset is used for the shifted_bitmask
		IF opcode(10 downto 8)="111" THEN --INS
			bf_loffset <= 32-bf_shift;
		ELSE
			bf_loffset <= bf_shift;
		END IF;
		bf_loffset(5) <= '0';
		
		IF opcode(4 downto 3)="00" THEN
			IF opcode(10 downto 8)="111" THEN --INS
				bf_shift <= bf_bhits+1;
			ELSE
				bf_shift <= 31-bf_bhits;
			END IF;
			bf_shift(5) <= '0';
		ELSE
			IF opcode(10 downto 8)="111" THEN --INS
				bf_shift <= "011001"+("000"&bf_bhits(2 downto 0));
				bf_shift(5) <= '0';
			ELSE
				bf_shift <= "000"&("111"-bf_bhits(2 downto 0));
			END IF;
			bf_offset(4 downto 3) <= "00";
		END IF;
		
		CASE bf_bhits(5 downto 3) IS
			WHEN "000" =>
				set_memmask <= "101111";
			WHEN "001" =>
				set_memmask <= "100111";
			WHEN "010" =>
				set_memmask <= "100011";
			WHEN "011" =>
				set_memmask <= "100001";
			WHEN OTHERS =>
				set_memmask <= "100000";
		END CASE;	
		IF setstate="00" THEN
			set_memmask <= "100111";
		END IF;
	END PROCESS;		
	
------------------------------------------------------------------------------
--SR op
------------------------------------------------------------------------------		
PROCESS (clk, Reset, FlagsSR, last_data_read, OP2out, exec)
	BEGIN
		IF exec(andiSR)='1' THEN
			SRin <= FlagsSR AND last_data_read(15 downto 8);
		ELSIF exec(eoriSR)='1' THEN
			SRin <= FlagsSR XOR last_data_read(15 downto 8);
		ELSIF exec(oriSR)='1' THEN
			SRin <= FlagsSR OR last_data_read(15 downto 8);
		ELSE	
			SRin <= OP2out(15 downto 8);
		END IF;	
		
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				fc_int(2) <= '1';
				SVmode <= '1';
				preSVmode <= '1';
				FlagsSR <= "00100111";
				make_trace <= '0';
				preMmode <= '0';
				exec_chgM <= '0';
			ELSIF clkena_lw = '1' THEN
				exec_chgM <= set_chgM;
				chgM_S <= preSVmode;
				IF set_chgM='1' THEN
					preMmode <= NOT preMmode;
				END IF;
				IF micro_state=thr0 THEN
					FlagsSR(4) <= '0';		-- interrupt with M set: on to the ISP
				END IF;
				IF setopcode='1' THEN
					make_trace <= FlagsSR(7);
					IF set(changeMode)='1' THEN
						SVmode <= NOT SVmode; 
					ELSE
						SVmode <= preSVmode;
					END IF;	
				END IF;
				IF trap_berr='1' OR trap_illegal='1' OR trap_addr_error='1' OR trap_priv='1' OR trap_1010='1' OR trap_1111='1' THEN
					make_trace <= '0';
					FlagsSR(7) <= '0';
				END IF;
				IF micro_state=rte_ferr THEN
					FlagsSR <= rte_sr;		-- the SR before the RTE
				END IF;
				IF xc_now='1' THEN
					-- address error entry: S set (an RTE may have loaded a user SR
					-- already), T cleared, and the switch to the supervisor stack
					FlagsSR(5) <= '1';
					FlagsSR(7) <= '0';
					make_trace <= '0';
					IF preSVmode='0' THEN
						preSVmode <= '1';
						fc_int(2) <= '1';
					END IF;
				END IF;
				IF set(changeMode)='1' THEN
					preSVmode <= NOT preSVmode;
					FlagsSR(5) <= NOT preSVmode;
					fc_int(2) <= NOT preSVmode;
				END IF;
				IF micro_state=trap3 THEN
					FlagsSR(7) <= '0';
				END IF;
				IF trap_trace='1' AND state="10" THEN
					make_trace <= '0';
				END IF;
				IF exec(directSR)='1' OR set_stop='1' THEN
					FlagsSR <= data_read(15 downto 8);
				END IF;	
				IF interrupt='1' AND trap_interrupt='1' THEN
					FlagsSR(2 downto 0) <=rIPL_nr;
				END IF;	
				IF exec(to_SR)='1' THEN
					FlagsSR(7 downto 0) <= SRin;	--SR
					fc_int(2) <= SRin(5);
				ELSIF exec(update_FC)='1' THEN
					fc_int(2) <= FlagsSR(5);
				END IF;
				IF interrupt='1' THEN
					fc_int(2) <= '1';
				END IF;	
				IF cpu(1)='0' THEN
					FlagsSR(4) <= '0';
					FlagsSR(6) <= '0';
				END IF;
				FlagsSR(3) <= '0';
			END IF;
		END IF;	
	END PROCESS;

-----------------------------------------------------------------------------
-- Level 7 is edge-triggered (M68000 User's Manual): an interrupt is
-- generated each time the request rises to 7 from a lower level, even with
-- the mask at 7. A held 7 is only taken again through the normal level
-- comparison, once an instruction lowers the mask below 7. It used to be
-- taken whenever IPL was 7, so a held request was taken again at the end
-- of every exception entry and its handler never ran.
-----------------------------------------------------------------------------
PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				ipl7_last <= '0';
				nmi_pending <= '0';
			ELSE
				IF IPL_nr="111" THEN
					ipl7_last <= '1';
				ELSE
					ipl7_last <= '0';
				END IF;
				IF IPL_nr="111" AND ipl7_last='0' THEN
					nmi_pending <= '1';
				ELSIF clkena_lw='1' AND setinterrupt='1' AND make_trace='0' AND make_berr='0' AND IPL_nr="111" THEN
					nmi_pending <= '0';				-- taken (see trap_interrupt below)
				END IF;
			END IF;
		END IF;
	END PROCESS;

-----------------------------------------------------------------------------
-- SR.M selects the MSP or the ISP (68020 and later): the stack pointers are
-- swapped where a change of S swaps them, and within exception processing
-- for an interrupt taken with M set and an RTE of a format $1 frame
-----------------------------------------------------------------------------
	set_chgM <= '1' WHEN cpu(1)='1' AND FlagsSR(4)/=preMmode AND (setexecOPC='1' OR micro_state=rte_f1) ELSE
				'1' WHEN micro_state=thr0 ELSE '0';

-----------------------------------------------------------------------------
-- decode opcode
-----------------------------------------------------------------------------
PROCESS (clk, cpu, OP1out, OP2out, opcode, exe_condition, nextpass, micro_state, decodeOPC, state, setexecOPC, Flags, FlagsSR, direct_data, build_logical,
		 build_bcd, set_Z_error, trapd, movem_run, last_data_read, set, set_V_Flag, z_error, trap_trace, trap_interrupt,
		 SVmode, preSVmode, stop, long_done, ea_only, setstate, addrvalue, execOPC, exec_write_back, exe_datatype,
		 datatype, interrupt, c_out, trapmake, rot_cnt, brief, addr, trap_trapv, last_data_in, use_VBR_Stackframe,
		 long_start, set_datatype, sndOPC, set_exec, exec, ea_build_now, reg_QA, reg_QB, make_berr, trap_berr,
		 cpu040, m16_done, fpu_ins, fpu_gen, fpu_memea, fpu_fbcc, fpu_unimpl, fpu_badcmd, fpu_done, mmu_ptest_done,
		 fpu_unimp, fpu_trap2, fpu_ftrap, fpu_unsupp, fpu_upost, fpu_trap55, set_chgM, thr_pass,
		 fpu_xexc, fpu_xpost, fpu_trapx, fpu_fbx)
	BEGIN
		TG68_PC_brw <= '0';	
		setstate <= "00";
		setaddrvalue <= '0';
		Regwrena_now <= '0';
		movem_presub <= '0';
		setnextpass <= '0';
		regdirectsource <= '0';
		setdisp <= '0';
		setdispbyte <= '0';
		getbrief <= '0';
		dest_LDRareg <= '0';
		dest_areg <= '0';
		source_areg <= '0';
		data_is_source <= '0';
		write_back <= '0';
		setstackaddr <= '0';
		writePC <= '0';
		ea_build_now <= '0';
--		set_rot_bits <= "00";
		set_rot_bits <= opcode(4 downto 3);
		set_rot_cnt <= "000001";
		dest_hbits <= '0';
		source_lowbits <= '0';
		source_LDRLbits <= '0';
		source_LDRMbits <= '0';
		source_2ndHbits <= '0';
		source_2ndMbits <= '0';
		source_2ndLbits <= '0';
		dest_LDRHbits <= '0';
		dest_LDRLbits <= '0';
		dest_2ndHbits <= '0';
		dest_2ndLbits <= '0';
		ea_only <= '0';
		set_direct_data <= '0';
		set_exec_tas <= '0';
		trap_illegal <='0';
		trap_addr_error <= '0';
		trap_priv <='0';
		trap_1010 <='0';
		trap_1111 <='0';
		trap_fmt <= '0';
		trap_unsupp <= '0';
		trap_fpx <= '0';
		trap_trap <='0';
		trap_trapv <= '0';
		trapmake <='0';
		set_vectoraddr <='0';
		writeSR <= '0';
		set_stop <= '0';
--		illegal_write_mode <= '0';
--		illegal_read_mode <= '0';
--		illegal_byteaddr <= '0';
		set_Z_error <= '0';
		check_aligned <='0';

		next_micro_state <= idle;
		build_logical <= '0';
		build_bcd <= '0';
		skipFetch_i <= make_berr;
		set_writePCbig <= '0';
--		set_recall_last <= '0';
		set_Suppress_Base <= '0';
		set_PCbase <= '0';
						
		IF rot_cnt/="000001" THEN
			set_rot_cnt <= rot_cnt-1;
		END IF;	
		set_datatype <= datatype;
		
		set <= (OTHERS=>'0');
		set_exec <= (OTHERS=>'0');
		set(update_ld) <= '0';
--		odd_start <= '0';
------------------------------------------------------------------------------
--Sourcepass
------------------------------------------------------------------------------		
		CASE opcode(7 downto 6) IS
			WHEN "00" => datatype <= "00";		--Byte
			WHEN "01" => datatype <= "01";		--Word
			WHEN OTHERS => datatype <= "10";	--Long
		END CASE;

		IF execOPC='1' AND exec_write_back='1' THEN
			set(restore_ADDR) <= '1';
		END IF;
		
		IF interrupt='1' AND trap_berr='1' THEN
			next_micro_state <= trap0;
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;	
		IF trapmake='1' AND trapd='0' THEN
			-- exec(trap_chk) still holds a CHK that did not trap during the decode
			-- cycle of the next instruction: a CHK only traps outside decode
			IF cpu(1)='1' AND (trap_trapv='1' OR set_Z_error='1' OR (exec(trap_chk)='1' AND decodeOPC='0') OR fpu_trap2='1' OR (fpu_trap55='1' AND fpu_upost='1') OR (fpu_trapx='1' AND fpu_xpost='1')) THEN
				next_micro_state <= trap00;
			else
				next_micro_state <= trap0;
			end if;
			IF use_VBR_Stackframe='0' THEN
				set(writePC_add) <= '1';
--				set_datatype <= "10";
			END IF;
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;	
		IF micro_state=int1 OR (interrupt='1' AND trap_trace='1') THEN
-- paste and copy form TH	---------	
			if trap_trace='1' AND cpu(1) = '1' then
				next_micro_state <= trap00;  --TH
			else
				next_micro_state <= trap0;
			end if;
------------------------------------
--			next_micro_state <= trap0;
--			IF cpu(0)='0' THEN
--				set_datatype <= "10";
--			END IF;
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;	
	if micro_state = int1 or (interrupt = '1' and trap_trace = '1') then
	  if preSVmode = '0' then
		set(changeMode) <= '1';
	  end if;
	  setstate <= "01";
	end if;
		
		IF setexecOPC='1' AND FlagsSR(5)/=preSVmode THEN
			set(changeMode) <= '1';
--			setstate <= "01";
--			next_micro_state <= nop;
		END IF;

		IF interrupt='1' AND trap_interrupt='1'THEN
--			skipFetch <= '1';
			next_micro_state <= int1;
			set(update_ld) <= '1';
			setstate <= "10";
		END IF;
			
		IF set(changeMode)='1' THEN		
			set(to_USP) <= '1';
			set(from_USP) <= '1';
			setstackaddr <='1';
		END IF;
		IF set_chgM='1' THEN
			setstackaddr <='1';
		END IF;
			
		IF ea_only='0' AND set(get_ea_now)='1' THEN
			setstate <= "10";
--			set_recall_last <= '1';
--			set(update_ld) <= '0';
		END IF;

		IF setstate(1)='1' AND set_datatype(1)='1' THEN
			set(longaktion) <= '1';
		END IF;

		IF (ea_build_now='1' AND decodeOPC='1') OR exec(ea_build)='1' THEN
			CASE opcode(5 downto 3) IS		--source
				WHEN "010"|"011"|"100" =>						-- -(An)+
					set(get_ea_now) <='1';
					setnextpass <= '1';
					IF opcode(3)='1' THEN	--(An)+
						set(postadd) <= '1';
						IF opcode(2 downto 0)="111" THEN
							set(use_SP) <= '1';
						END IF;
					END IF;	 	
					IF opcode(5)='1' THEN	-- -(An)
						set(presub) <= '1'; 					
						IF opcode(2 downto 0)="111" THEN
							set(use_SP) <= '1';
						END IF;
					END IF;	 	
				WHEN "101" =>				--(d16,An)
					next_micro_state <= ld_dAn1;
				WHEN "110" =>				--(d8,An,Xn)
					next_micro_state <= ld_AnXn1;
					getbrief <='1';
				WHEN "111" =>
					CASE opcode(2 downto 0) IS
						WHEN "000" =>				--(xxxx).w
							next_micro_state <= ld_nn;
						WHEN "001" =>				--(xxxx).l
							set(longaktion) <= '1';
							next_micro_state <= ld_nn;
						WHEN "010" =>				--(d16,PC)
							next_micro_state <= ld_dAn1;
							set(dispouter) <= '1';
							set_Suppress_Base <= '1';
							set_PCbase <= '1';
						WHEN "011" =>				--(d8,PC,Xn)
							next_micro_state <= ld_AnXn1;
							getbrief <= '1';
							set(dispouter) <= '1';
							set_Suppress_Base <= '1';
							set_PCbase <= '1';
						WHEN "100" =>				--#data
							setnextpass <= '1';
							set_direct_data <= '1';
							IF datatype="10" THEN
								set(longaktion) <= '1';
							END IF;
						WHEN OTHERS => NULL;
					END CASE;
				WHEN OTHERS => NULL;
			END CASE;
		END IF;
------------------------------------------------------------------------------
--prepare opcode
------------------------------------------------------------------------------
		CASE opcode(15 downto 12) IS
-- 0000 ----------------------------------------------------------------------------
			WHEN "0000" =>
			IF opcode(8)='1' AND opcode(5 downto 3)="001" THEN --movep
				datatype <= "00";				--Byte
				set(use_SP) <= '1';		--addr+2
				set(no_Flags) <='1';
				IF opcode(7)='0' THEN  --to register
					set_exec(Regwrena) <= '1';
					set_exec(opcMOVE) <= '1';
					set(movepl) <= '1';
				END IF;
				IF decodeOPC='1' THEN
					IF opcode(6)='1' THEN
						set(movepl) <= '1';
					END IF;
					IF opcode(7)='0' THEN
						set_direct_data <= '1';		-- to register
					END IF;
					next_micro_state <= movep1;
				END IF;
				IF setexecOPC='1' THEN
					dest_hbits <='1';
				END IF;
			ELSE
				IF opcode(8)='1' OR opcode(11 downto 9)="100" THEN		--Bits
					IF opcode(5 downto 3)/="001" AND --ea An illegal mode
					   (opcode(8 downto 3)/="000111" OR opcode(2)='0') AND --BTST bit number static illegal modes
					   (opcode(8 downto 2)/="1001111" OR opcode(1 downto 0)="00") AND --BTST bit number dynamic illegal modes
					   (opcode(7 downto 6)="00" OR opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --BCHG, BCLR, BSET illegal modes
						set_exec(opcBITS) <= '1';
						set_exec(ea_data_OP1) <= '1';
						IF opcode(7 downto 6)/="00" THEN
							IF opcode(5 downto 4)="00" THEN
								set_exec(Regwrena) <= '1';
							END IF;
							write_back <= '1';
						END IF;
						IF opcode(5 downto 4)="00" THEN
							datatype <= "10";			--Long
						ELSE
							datatype <= "00";			--Byte
						END IF;
						IF opcode(8)='0' THEN
							IF decodeOPC='1' THEN
								next_micro_state <= nop;
								set(get_2ndOPC) <= '1';
								set(ea_build) <= '1';
							END IF;
						ELSE
							ea_build_now <= '1';
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(8 downto 6)="011" THEN			--CAS/CAS2/CMP2/CHK2
					IF cpu(1)='1' THEN
						IF opcode(11)='1' THEN					--CAS/CAS2
							IF (opcode(10 downto 9)/="00" AND --CAS illegal size
							   opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) OR --ea illegal modes
							   (opcode(10)='1' AND opcode(5 downto 0)="111100") THEN --CAS2
								CASE opcode(10 downto 9) IS
									WHEN "01" => datatype <= "00";		--Byte
									WHEN "10" => datatype <= "01";		--Word
									WHEN OTHERS => datatype <= "10";	--Long
								END CASE;
								IF opcode(10)='1' AND opcode(5 downto 0)="111100" THEN --CAS2
									IF decodeOPC='1' THEN
										set(get_2ndOPC) <= '1';
										next_micro_state <= cas21;
									END IF;
								ELSE											--CAS
									IF decodeOPC='1' THEN
										next_micro_state <= nop;
										set(get_2ndOPC) <= '1';
										set(ea_build) <= '1';
									END IF;
									IF micro_state=idle AND nextpass='1' THEN
										source_2ndLbits <= '1';
										set(ea_data_OP1) <= '1';
										set(addsub) <= '1';
										set(alu_exec) <= '1';
										set(alu_setFlags) <= '1';
										setstate <= "01";
										next_micro_state <= cas1;
									END IF;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSE				--CMP2/CHK2
							IF opcode(10 downto 9)/="11" AND --illegal size
							   opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="011" AND opcode(5 downto 3)/="100" AND opcode(5 downto 2)/="1111" THEN --ea illegal modes
								set(trap_chk) <= '1';
								datatype <= opcode(10 downto 9);
								IF decodeOPC='1' THEN
									next_micro_state <= nop;
									set(get_2ndOPC) <= '1';
									set(ea_build) <= '1';
								END IF;
								IF set(get_ea_now)='1' THEN
									set(mem_addsub) <= '1';
									set(OP1addr) <= '1';
								END IF;
								IF micro_state=idle AND nextpass='1' THEN
									setstate <= "10";
									set(hold_OP2) <='1';
									IF exe_datatype/="00" THEN
										check_aligned <='1';
									END IF;
									next_micro_state <= chk20;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(11 downto 9)="111" THEN		--MOVES not in 68000
					IF cpu010='1' AND opcode(7 downto 6)/="11" AND opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
						IF SVmode='1' THEN
							--TODO: implement MOVES
							trap_illegal <= '1';
							trapmake <= '1';
						ELSE
							trap_priv <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSE								--andi, ...xxxi
					IF opcode(7 downto 6)/="11" AND opcode(5 downto 3)/="001" THEN --ea An illegal mode
						IF opcode(11 downto 9)="000" THEN	--ORI
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" OR (opcode(2 downto 0)="100" AND opcode(7)='0') THEN
								set_exec(opcOR) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="001" THEN	--ANDI
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" OR (opcode(2 downto 0)="100" AND opcode(7)='0') THEN
								set_exec(opcAND) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="010" OR opcode(11 downto 9)="011" THEN	--SUBI, ADDI
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" THEN
								set_exec(opcADD) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="101" THEN	--EORI
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" OR (opcode(2 downto 0)="100" AND opcode(7)='0') THEN
								set_exec(opcEOR) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="110" THEN	--CMPI
							IF opcode(5 downto 3)/="111" OR opcode(2)='0' THEN
								set_exec(opcCMP) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF (set_exec(opcor) OR set_exec(opcand) OR set_exec(opcADD) OR set_exec(opcEor) OR set_exec(opcCMP))='1' THEN
							IF opcode(7)='0' AND opcode(5 downto 0)="111100" AND (set_exec(opcAND) OR set_exec(opcOR) OR set_exec(opcEOR))='1' THEN		--SR
								IF decodeOPC='1' AND SVmode='0' AND opcode(6)='1' THEN  --SR
									trap_priv <= '1';
									trapmake <= '1';
								ELSE
									set(no_Flags) <= '1';
									IF decodeOPC='1' THEN
										IF opcode(6)='1' THEN
											set(to_SR) <= '1';
										END IF;
										set(to_CCR) <= '1';
										set(andiSR) <= set_exec(opcAND);
										set(eoriSR) <= set_exec(opcEOR);
										set(oriSR) <= set_exec(opcOR);
										setstate <= "01";
										next_micro_state <= nopnop;
									END IF;
								END IF;
							ELSIF opcode(7)='0' OR opcode(5 downto 0)/="111100" OR (set_exec(opcand) OR set_exec(opcor) OR set_exec(opcEor))='0' THEN
								IF decodeOPC='1' THEN
									next_micro_state <= andi;
									set(get_2ndOPC) <='1';
									set(ea_build) <= '1';
									set_direct_data <= '1';
									IF datatype="10" THEN
										set(longaktion) <= '1';
									END IF;
								END IF;
								IF opcode(5 downto 4)/="00" THEN
									set_exec(ea_data_OP1) <= '1';
								END IF;
								IF opcode(11 downto 9)/="110" THEN	--CMPI
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									write_back <= '1';
								END IF;
								IF opcode(10 downto 9)="10" THEN	--CMPI, SUBI
									set(addsub) <= '1';
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				END IF;
			END IF;
				
-- 0001, 0010, 0011 -----------------------------------------------------------------
			WHEN "0001"|"0010"|"0011" =>				--move.b, move.l, move.w
				IF ((opcode(11 downto 10)="00" OR opcode(8 downto 6)/="111") AND --illegal dest ea
				   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") AND --illegal src ea
				   (opcode(13)='1' OR (opcode(8 downto 6)/="001" AND opcode(5 downto 3)/="001"))) THEN --byte src address reg direct, byte movea
					set_exec(opcMOVE) <= '1';
					ea_build_now <= '1';
					IF opcode(8 downto 6)="001" THEN
						set(no_Flags) <= '1';
					END IF;
					IF opcode(5 downto 4)="00" THEN	--Dn, An
						IF opcode(8 downto 7)="00" THEN
							set_exec(Regwrena) <= '1';
						END IF;
					END IF;
					CASE opcode(13 downto 12) IS
						WHEN "01" => datatype <= "00";		--Byte
						WHEN "10" => datatype <= "10";		--Long
						WHEN OTHERS => datatype <= "01";	--Word
					END CASE;
					source_lowbits <= '1';					-- Dn=>  An=>
					IF opcode(3)='1' THEN
						source_areg <= '1';
					END IF;

					IF nextpass='1' OR opcode(5 downto 4)="00" THEN
						dest_hbits <= '1';
						IF opcode(8 downto 6)/="000" THEN
							dest_areg <= '1';
						END IF;
					END IF;

					IF micro_state=idle AND (nextpass='1' OR (opcode(5 downto 4)="00" AND decodeOPC='1')) THEN
						CASE opcode(8 downto 6) IS		--destination
							WHEN "000"|"001" =>						--Dn,An
									set_exec(Regwrena) <= '1';
							WHEN "010"|"011"|"100" =>					--destination -(an)+
								IF opcode(6)='1' THEN	--(An)+
									set(postadd) <= '1';
									IF opcode(11 downto 9)="111" THEN
										set(use_SP) <= '1';
									END IF;
								END IF;
								IF opcode(8)='1' THEN	-- -(An)
									set(presub) <= '1';
									IF opcode(11 downto 9)="111" THEN
										set(use_SP) <= '1';
									END IF;
								END IF;
								setstate <= "11";
								next_micro_state <= nop;
								IF nextpass='0' THEN
									set(write_reg) <= '1';
								END IF;
							WHEN "101" =>				--(d16,An)
								next_micro_state <= st_dAn1;
--								getbrief <= '1';
							WHEN "110" =>				--(d8,An,Xn)
								next_micro_state <= st_AnXn1;
								getbrief <= '1';
							WHEN "111" =>
								CASE opcode(11 downto 9) IS
									WHEN "000" =>				--(xxxx).w
										next_micro_state <= st_nn;
									WHEN "001" =>				--(xxxx).l
										set(longaktion) <= '1';
										next_micro_state <= st_nn;
									WHEN OTHERS => NULL;
								END CASE;
							WHEN OTHERS => NULL;
						END CASE;
					END IF;
				ELSE
					trap_illegal <= '1';
					trapmake <= '1';
				END IF;
---- 0100 ----------------------------------------------------------------------------		
			WHEN "0100" =>				--rts_group
				IF opcode(8)='1' THEN		--lea, extb.l, chk
					IF opcode(6)='1' THEN		--lea, extb.l
						IF opcode(11 downto 9)="100" AND opcode(5 downto 3)="000" THEN --extb.l
							IF opcode(7)='1' AND cpu(1)='1' THEN
								source_lowbits <= '1';
								set_exec(opcEXT) <= '1';
								set_exec(opcEXTB) <= '1';
								set_exec(opcMOVE) <= '1';
								set_exec(Regwrena) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							IF opcode(7)='1' AND
							   (opcode(5)='1' OR opcode(4 downto 3)="10") AND
							   opcode(5 downto 3)/="100" AND opcode(5 downto 2)/="1111" THEN --ea illegal opcodes
								source_lowbits <= '1';
								source_areg <= '1';
								ea_only <= '1';
								set_exec(Regwrena) <= '1';
								set_exec(opcMOVE) <='1';
								set(no_Flags) <='1';
								IF opcode(5 downto 3)="010" THEN  	--lea (Am),An
									dest_areg <= '1';
									dest_hbits <= '1';
								ELSE
									ea_build_now <= '1';
								END IF;	
								IF set(get_ea_now)='1' THEN
									setstate <= "01";
									set_direct_data <= '1';
								END IF;
								IF setexecOPC='1' THEN
									dest_areg <= '1';
									dest_hbits <= '1';
								END IF;
							ELSE
								trap_illegal <='1';
								trapmake <='1';
							END IF;
						END IF;
					ELSE								--chk
						IF opcode(5 downto 3)/="001" AND --ea An illegal mode
						   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --ea illegal modes
							IF opcode(7)='1' THEN
								datatype <= "01";	--Word
								set(trap_chk) <= '1';
								IF (c_out(1)='0' OR OP1out(15)='1' OR OP2out(15)='1') AND exec(opcCHK)='1' THEN
									trapmake <= '1';
								END IF;
							ELSIF cpu(1)='1' THEN   --chk long for 68020
								datatype <= "10";	--Long
								set(trap_chk) <= '1';
								IF (c_out(2)='0' OR OP1out(31)='1' OR OP2out(31)='1') AND exec(opcCHK)='1' THEN
									trapmake <= '1';
								END IF;
							ELSE
								trap_illegal <= '1';		-- chk long for 68020
								trapmake <= '1';
							END IF;
							IF opcode(7)='1' OR cpu(1)='1' THEN
								IF (nextpass='1' OR opcode(5 downto 4)="00") AND exec(opcCHK)='0' AND micro_state=idle THEN
									set_exec(opcCHK) <= '1';
								END IF;
								ea_build_now <= '1';
								set(addsub) <= '1';
								IF setexecOPC='1' THEN
									dest_hbits <= '1';
									source_lowbits <='1';
								END IF;
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
				ELSE
					CASE opcode(11 downto 9) IS
						WHEN "000"=>
							IF (opcode(5 downto 3)/="001" AND --ea An illegal mode
							   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN --ea illegal modes
								IF opcode(7 downto 6)="11" THEN					--move from SR
									IF SR_Read=0 OR (cpu010='0' AND SR_Read=2) OR SVmode='1'  THEN
										ea_build_now <= '1';
										set_exec(opcMOVESR) <= '1';
										datatype <= "01";
										write_back <='1';							-- im 68000 wird auch erst gelesen
										IF cpu010='1' AND state="10" AND addrvalue='0' THEN
											skipFetch_i <= '1';
										END IF;
										IF opcode(5 downto 4)="00" THEN
											set_exec(Regwrena) <= '1';
										END IF;
									ELSE
										trap_priv <= '1';
										trapmake <= '1';
									END IF;
								ELSE									--negx
									ea_build_now <= '1';
									set_exec(use_XZFlag) <= '1';
									write_back <='1';
									set_exec(opcADD) <= '1';
									set(addsub) <= '1';
									source_lowbits <= '1';
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP1out_zero) <= '1';
									END IF;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						WHEN "001"=>
							IF (opcode(5 downto 3)/="001" AND --ea An illegal mode
							   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN --ea illegal modes
								IF opcode(7 downto 6)="11" THEN					--move from CCR 68010
									IF SR_Read=1 OR (cpu010='1' AND SR_Read=2) THEN
										ea_build_now <= '1';
										set_exec(opcMOVESR) <= '1';
										datatype <= "01";
										write_back <='1';							-- im 68000 wird auch erst gelesen
--										IF state="10" THEN
--											skipFetch <= '1';
--										END IF;
										IF opcode(5 downto 4)="00" THEN
											set_exec(Regwrena) <= '1';
										END IF;
									ELSE
										trap_illegal <= '1';
										trapmake <= '1';
									END IF;
								ELSE											--clr
									ea_build_now <= '1';
									write_back <='1';
									set_exec(opcAND) <= '1';
									IF cpu010='1' AND state="10" AND addrvalue='0' THEN
										skipFetch_i <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP1out_zero) <= '1';
									END IF;
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						WHEN "010"=>
							IF opcode(7 downto 6)="11" THEN					--move to CCR
								IF opcode(5 downto 3)/="001" AND --ea An illegal mode
								   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --ea illegal modes
									ea_build_now <= '1';
									datatype <= "01";
									source_lowbits <= '1';
									IF (decodeOPC='1' AND opcode(5 downto 4)="00") OR (state="10" AND addrvalue='0') OR direct_data='1' THEN
										set(to_CCR) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							ELSE											--neg
								IF (opcode(5 downto 3)/="001" AND --ea An illegal mode
								   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN --ea illegal modes
									ea_build_now <= '1';
									write_back <='1';
									set_exec(opcADD) <= '1';
									set(addsub) <= '1';
									source_lowbits <= '1';
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP1out_zero) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							END IF;
						WHEN "011"=>										--not, move toSR
							IF opcode(7 downto 6)="11" THEN					--move to SR
								IF opcode(5 downto 3)/="001" AND --ea An illegal mode
								   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --ea illegal modes
									IF SVmode='1' THEN
										ea_build_now <= '1';
										datatype <= "01";
										source_lowbits <= '1';
										IF (decodeOPC='1' AND opcode(5 downto 4)="00") OR (state="10" AND addrvalue='0') OR direct_data='1' THEN
											set(to_SR) <= '1';
											set(to_CCR) <= '1';
										END IF;
										IF exec(to_SR)='1' OR (decodeOPC='1' AND opcode(5 downto 4)="00") OR (state="10" AND addrvalue='0') OR direct_data='1' THEN
											setstate <="01";
										END IF;
									ELSE
										trap_priv <= '1';
										trapmake <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							ELSE											--not
								IF opcode(5 downto 3)/="001" AND --ea An illegal mode
								   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --ea illegal modes
									ea_build_now <= '1';
									write_back <='1';
									set_exec(opcEOR) <= '1';
									set_exec(ea_data_OP1) <= '1';
									IF opcode(5 downto 3)="000" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP2out_one) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							END IF;
						WHEN "100"|"110"=>
							IF opcode(7)='1' THEN			--movem, ext
								IF opcode(5 downto 3)="000" AND opcode(10)='0' THEN		--ext
									source_lowbits <= '1';
									set_exec(opcEXT) <= '1';
									set_exec(opcMOVE) <= '1';
									set_exec(Regwrena) <= '1';	
									IF opcode(6)='0' THEN
										datatype <= "01";		--WORD
										set_exec(opcEXTB) <= '1';
									END IF;
								ELSE													--movem
--								IF opcode(11 downto 7)="10001" OR opcode(11 downto 7)="11001" THEN	--MOVEM
									IF (opcode(10)='1' OR ((opcode(5)='1' OR opcode(4 downto 3)="10") AND
									   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) AND
									   (opcode(10)='0' OR (opcode(5 downto 4)/="00" AND
									   opcode(5 downto 3)/="100" AND
									   opcode(5 downto 2)/="1111")) THEN --ea illegal modes
										ea_only <= '1';
										set(no_Flags) <= '1';
										IF opcode(6)='0' THEN
											datatype <= "01";		--Word transfer
										END IF;
										IF (opcode(5 downto 3)="100" OR opcode(5 downto 3)="011") AND state="01" THEN	-- -(An), (An)+
											set_exec(save_memaddr) <= '1';
											set_exec(Regwrena) <= '1';
										END IF;
										IF opcode(5 downto 3)="100" THEN	-- -(An)
											movem_presub <= '1';
											set(subidx) <= '1';
										END IF;
										IF state="10" AND addrvalue='0' THEN
											set(Regwrena) <= '1';
											set(opcMOVE) <= '1';
										END IF;
										IF decodeOPC='1' THEN
											set(get_2ndOPC) <='1';
											IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
												next_micro_state <= movem1;
											ELSE
												next_micro_state <= nop;
												set(ea_build) <= '1';
											END IF;
										END IF;
										IF set(get_ea_now)='1' THEN
											IF movem_run='1' THEN
												set(movem_action) <= '1';
												IF opcode(10)='0' THEN
													setstate <="11";
													set(write_reg) <= '1';
												ELSE
													setstate <="10";
												END IF;
												next_micro_state <= movem2;
												set(mem_addsub) <= '1';
											ELSE
												setstate <="01";
											END IF;
										END IF;
									ELSE
										trap_illegal <= '1';
										trapmake <= '1';
									END IF;
								END IF;	
							ELSE
								IF opcode(10)='1' THEN						--MUL.L, DIV.L 68020
	 --FPGA Multiplier for long							
									IF opcode(8 downto 7)="00" AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") AND--ea An illegal mode
									   MUL_Hardware=1 AND (opcode(6)='0' AND (MUL_Mode=1 OR (cpu(1)='1' AND MUL_Mode=2))) THEN
										IF decodeOPC='1' THEN
											next_micro_state <= nop;
											set(get_2ndOPC) <= '1';
											set(ea_build) <= '1';
										END IF;
										IF (micro_state=idle AND nextpass='1') OR (opcode(5 downto 4)="00" AND exec(ea_build)='1') THEN
											dest_2ndHbits <= '1';
											datatype <= "10";
											set(opcMULU) <= '1';
											set(write_lowlong) <= '1';
											IF sndOPC(10)='1' THEN
												setstate <="01";
												next_micro_state <= mul_end2;
											END IF;
											set(Regwrena) <= '1';
										END IF;
										source_lowbits <='1';
										datatype <= "10";

	 --no FPGA Multiplier
									ELSIF opcode(8 downto 7)="00" AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") AND --ea An illegal mode
									   ((opcode(6)='1' AND (DIV_Mode=1 OR (cpu(1)='1' AND DIV_Mode=2))) OR
									   (opcode(6)='0' AND (MUL_Mode=1 OR (cpu(1)='1' AND MUL_Mode=2)))) THEN
										IF decodeOPC='1' THEN
											next_micro_state <= nop;
											set(get_2ndOPC) <= '1';
											set(ea_build) <= '1';
										END IF;
										IF (micro_state=idle AND nextpass='1') OR (opcode(5 downto 4)="00" AND exec(ea_build)='1')THEN
											setstate <="01";
											dest_2ndHbits <= '1';
											source_2ndLbits <= '1';
											IF opcode(6)='1' THEN
												next_micro_state <= div1;
											ELSE	
												next_micro_state <= mul1;
												set(ld_rot_cnt) <= '1';
											END IF;
										END IF;
										source_lowbits <='1';
										IF nextpass='1' OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN	
											dest_hbits <= '1';
										END IF;
										datatype <= "10";
									ELSE
										trap_illegal <= '1';
										trapmake <= '1';
									END IF;
					
								ELSE							--pea, swap
									IF opcode(6)='1' THEN
										datatype <= "10";
										IF opcode(5 downto 3)="000" THEN 		--swap
											set_exec(opcSWAP) <= '1';
											set_exec(Regwrena) <= '1';	
										ELSIF opcode(5 downto 3)="001" THEN 		--bkpt
											trap_illegal <= '1';
											trapmake <= '1';
										ELSE									--pea
											IF (opcode(5)='1' OR opcode(4 downto 3)="10") AND
											   opcode(5 downto 3)/="100" AND
											   opcode(5 downto 2)/="1111" THEN --ea illegal modes
												ea_only <= '1';
												ea_build_now <= '1';
												IF nextpass='1' AND micro_state=idle THEN
													set(presub) <= '1';
													setstackaddr <='1';
													setstate <="11";
													next_micro_state <= nop;
												END IF;
												IF set(get_ea_now)='1' THEN
													setstate <="01";
												END IF;
											ELSE
												trap_illegal <= '1';
												trapmake <= '1';
											END IF;
										END IF;
									ELSE
										IF opcode(5 downto 3)="001" THEN --link.l
											datatype <= "10";
											set_exec(opcADD) <= '1';						--for displacement
											set_exec(Regwrena) <= '1';
											set(no_Flags) <= '1';
											IF decodeOPC='1' THEN
												set(linksp) <= '1';
												set(longaktion) <= '1';
												next_micro_state <= link1;
												set(presub) <= '1';
												setstackaddr <='1';
												set(mem_addsub) <= '1';
												source_lowbits <= '1';
												source_areg <= '1';
												set(store_ea_data) <= '1';
											END IF;
										ELSE						--nbcd
											IF opcode(5 downto 3)/="001" AND --ea An illegal mode
											   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --ea illegal modes
												ea_build_now <= '1';
												set_exec(use_XZFlag) <= '1';
												write_back <='1';
												set_exec(opcADD) <= '1';
												set_exec(opcSBCD) <= '1';
												set(addsub) <= '1';
												source_lowbits <= '1';
												IF opcode(5 downto 4)="00" THEN
													set_exec(Regwrena) <= '1';
												END IF;
												IF setexecOPC='1' THEN
													set(OP1out_zero) <= '1';
												END IF;
											ELSE
												trap_illegal <= '1';
												trapmake <= '1';
											END IF;
										END IF;	
									END IF;
								END IF;
							END IF;
--0x4AXX							
						WHEN "101"=>						--tst, tas  4aFC - illegal
--							IF opcode(7 downto 2)="111111" THEN   --illegal
							IF opcode(7 downto 3)="11111" AND opcode(2 downto 1)/="00" THEN   --0x4AFC illegal  --0x4AFB BKP Sinclair QL
								trap_illegal <= '1';
								trapmake <= '1';
							ELSE
								IF (opcode(7 downto 6)/="11" OR --tas
								   (opcode(5 downto 3)/="001" AND --ea An illegal mode
								   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) AND --ea illegal modes
								   ((opcode(7 downto 6)/="00" OR (opcode(5 downto 3)/="001")) AND
								   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) THEN
									ea_build_now <= '1';
									IF setexecOPC='1' THEN
										source_lowbits <= '1';
										IF opcode(3)='1' THEN			--MC68020...
											source_areg <= '1';
										END IF;
									END IF;
									set_exec(opcMOVE) <= '1';
									IF opcode(7 downto 6)="11" THEN		--tas
										set_exec_tas <= '1';
										write_back <= '1';
										datatype <= "00";				--Byte
										IF opcode(5 downto 4)="00" THEN
											set_exec(Regwrena) <= '1';
										END IF;
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							END IF;
----						WHEN "110"=>
						WHEN "111"=>					--4EXX
--
--											ea_only <= '1';
--											ea_build_now <= '1';
--											IF nextpass='1' AND micro_state=idle THEN
--												set(presub) <= '1';
--												setstackaddr <='1';
--												set(mem_addsub) <= '1';
--												setstate <="11";
--												next_micro_state <= nop;
--											END IF;
--											IF set(get_ea_now)='1' THEN
--												setstate <="01";
--											END IF;
--								
								
								
								
							IF opcode(7)='1' THEN		--jsr, jmp
								IF (opcode(5)='1' OR opcode(4 downto 3)="10") AND
								   opcode(5 downto 3)/="100" AND opcode(5 downto 2)/="1111" THEN --ea illegal modes
									datatype <= "10";
									ea_only <= '1';
									ea_build_now <= '1';
									IF exec(ea_to_pc)='1' THEN
										next_micro_state <= nop;
									END IF;
									IF nextpass='1' AND micro_state=idle AND opcode(6)='0' THEN
										set(presub) <= '1';
										setstackaddr <='1';
										setstate <="11";
										next_micro_state <= nopnop;
									END IF;
								
									IF micro_state=ld_AnXn1 AND brief(8)='0'THEN			--JMP/JSR n(Ax,Dn)
										skipFetch_i <= '1';
									END IF;
									IF state="00" THEN
										writePC <= '1';
									END IF;
									set(hold_dwr) <= '1';
									IF set(get_ea_now)='1' THEN					--jsr
										IF exec(longaktion)='0' OR long_done='1' THEN
											skipFetch_i <= '1';
										END IF;
										setstate <="01";
										set(ea_to_pc) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							ELSE						--
								CASE opcode(6 downto 0) IS
									WHEN "1000000"|"1000001"|"1000010"|"1000011"|"1000100"|"1000101"|"1000110"|"1000111"|		--trap
									     "1001000"|"1001001"|"1001010"|"1001011"|"1001100"|"1001101"|"1001110"|"1001111" =>		--trap
											trap_trap <='1';
											trapmake <= '1';
									
									WHEN "1010000"|"1010001"|"1010010"|"1010011"|"1010100"|"1010101"|"1010110"|"1010111"=> 		--link word
										datatype <= "10";
										set_exec(opcADD) <= '1';						--for displacement
										set_exec(Regwrena) <= '1';
										set(no_Flags) <= '1';
										IF decodeOPC='1' THEN
											next_micro_state <= link1;
											set(presub) <= '1';
											setstackaddr <='1';
											set(mem_addsub) <= '1';
											source_lowbits <= '1';
											source_areg <= '1';
											set(store_ea_data) <= '1';
										END IF;
									
									WHEN "1011000"|"1011001"|"1011010"|"1011011"|"1011100"|"1011101"|"1011110"|"1011111" =>		--unlink
										datatype <= "10";
										set_exec(Regwrena) <= '1';
										set_exec(opcMOVE) <= '1';						
										set(no_Flags) <= '1';
										IF decodeOPC='1' THEN
											setstate <= "01";
											next_micro_state <= unlink1;
											set(opcMOVE) <= '1';
											set(Regwrena) <= '1';
											setstackaddr <='1';
											source_lowbits <= '1';
											source_areg <= '1';
										END IF;
									
									WHEN "1100000"|"1100001"|"1100010"|"1100011"|"1100100"|"1100101"|"1100110"|"1100111" =>		--move An,USP
										IF SVmode='1' THEN
--											set(no_Flags) <= '1';
											set(to_USP) <= '1';
											source_lowbits <= '1';
											source_areg <= '1';
											datatype <= "10";
										ELSE
											trap_priv <= '1';
											trapmake <= '1';
										END IF;
									
									WHEN "1101000"|"1101001"|"1101010"|"1101011"|"1101100"|"1101101"|"1101110"|"1101111" =>		--move USP,An
										IF SVmode='1' THEN
--											set(no_Flags) <= '1';
											set(from_USP) <= '1';
											datatype <= "10";
											set_exec(Regwrena) <= '1';
										ELSE
											trap_priv <= '1';
											trapmake <= '1';
										END IF;
									
									WHEN "1110000" =>					--reset
										IF SVmode='0' THEN
											trap_priv <= '1';
											trapmake <= '1';
										ELSE
											set(opcRESET) <= '1';
											IF decodeOPC='1' THEN
												set(ld_rot_cnt) <= '1'; 
												set_rot_cnt <= "000000";
											END IF;
										END IF;
										
									WHEN "1110001" =>					--nop
									
									WHEN "1110010" =>					--stop
										IF SVmode='0' THEN
											trap_priv <= '1';
											trapmake <= '1';
										ELSE
											IF decodeOPC='1' THEN
												setnextpass <= '1';
												set_stop <= '1';	
											END IF;
											IF stop='1' THEN
												skipFetch_i <= '1';
											END IF;		
											
										END IF;
									
									WHEN "1110011"|"1110111" =>  									--rte/rtr
										IF SVmode='1' OR opcode(2)='1' THEN
											IF decodeOPC='1' THEN
												setstate <= "10";
												set(postadd) <= '1';
												setstackaddr <= '1';
												IF opcode(2)='1' THEN
													set(directCCR) <= '1';
												ELSE	
													set(directSR) <= '1';	
												END IF;
												next_micro_state <= rte1;
											END IF;
										ELSE
											trap_priv <= '1';
											trapmake <= '1';
										END IF;
										
									WHEN "1110100" =>  									--rtd
										datatype <= "10";
										IF decodeOPC='1' THEN
											setstate <= "10";
											set(postadd) <= '1';
											setstackaddr <= '1';
											set(direct_delta) <= '1';
											set(directPC) <= '1';
											set_direct_data <= '1';
											next_micro_state <= rtd1;
										END IF;
										
										
									WHEN "1110101" =>  									--rts
										datatype <= "10";
										IF decodeOPC='1' THEN
											setstate <= "10";
											set(postadd) <= '1';
											setstackaddr <= '1';
											set(direct_delta) <= '1';	
											set(directPC) <= '1';
											next_micro_state <= nopnop;
										END IF;
										
									WHEN "1110110" =>  									--trapv
										IF decodeOPC='1' THEN
											setstate <= "01";
										END IF;	
										IF Flags(1)='1' AND state="01" THEN
											trap_trapv <= '1';
											trapmake <= '1';
										END IF;
										
									WHEN "1111010"|"1111011" =>  									--movec
										IF cpu="00" THEN
											trap_illegal <= '1';
											trapmake <= '1';
										ELSIF SVmode='0' THEN
											trap_priv <= '1';
											trapmake <= '1';
										ELSE
											datatype <= "10";	--Long
											IF last_data_read(11 downto 0)=X"800" THEN
												set(from_USP) <= '1';
												IF opcode(0)='1' THEN
													set(to_USP) <= '1';
												END IF;
											END IF;
											IF opcode(0)='0' THEN
												set_exec(movec_rd) <= '1';
											ELSE		
												set_exec(movec_wr) <= '1';
											END IF;
											IF decodeOPC='1' THEN
												next_micro_state <= movec1;
												getbrief <='1';
											END IF;
										END IF;
									
									WHEN OTHERS =>	
										trap_illegal <= '1';
										trapmake <= '1';
								END CASE;	
							END IF;
						WHEN OTHERS => NULL;
					END CASE;
				END IF;	
--					
---- 0101 ----------------------------------------------------------------------------
			WHEN "0101" => 								--subq, addq
					IF opcode(7 downto 6)="11" THEN --dbcc
						IF opcode(5 downto 3)="001" THEN --dbcc
							IF decodeOPC='1' THEN
								next_micro_state <= dbcc1;
								set(OP2out_one) <= '1';
								data_is_source <= '1';
							END IF;
						ELSIF opcode(5 downto 3)="111" AND (opcode(2 downto 1)="01" OR opcode(2 downto 0)="100") THEN	--trapcc
							IF cpu(1)='1' THEN							-- only 68020+
								IF opcode(2 downto 1)="01" THEN
									IF decodeOPC='1' THEN
										IF opcode(0)='1' THEN			--long
											set(longaktion) <= '1';
										END IF;
										next_micro_state <= nop;
									END IF;
								ELSE
									IF decodeOPC='1' THEN
										setstate <= "01";
									END IF;
								END IF;
								IF exe_condition='1' AND decodeOPC='0' THEN
									trap_trapv <= '1';
									trapmake <= '1';
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSIF (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --Scc
							datatype <= "00";			--Byte
							ea_build_now <= '1';
							write_back <= '1';
							set_exec(opcScc) <= '1';
							IF cpu010='1' AND state="10" AND addrvalue='0' THEN
								skipFetch_i <= '1';
							END IF;
							IF opcode(5 downto 4)="00" THEN
								set_exec(Regwrena) <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE					--addq, subq
						IF opcode(7 downto 3)/="00001" AND
						   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --ea illegal modes
							ea_build_now <= '1';
							IF opcode(5 downto 3)="001" THEN
								set(no_Flags) <= '1';
							END IF;
							IF opcode(8)='1' THEN
								set(addsub) <= '1';
							END IF;
							write_back <= '1';
							set_exec(opcADDQ) <= '1';
							set_exec(opcADD) <= '1';
							set_exec(ea_data_OP1) <= '1';
							IF opcode(5 downto 4)="00" THEN
								set_exec(Regwrena) <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
--				
---- 0110 ----------------------------------------------------------------------------		
			WHEN "0110" =>				--bra,bsr,bcc
				datatype <= "10";
				
				IF micro_state=idle THEN
					IF opcode(11 downto 8)="0001" THEN		--bsr
						set(presub) <= '1';
						setstackaddr <='1';
						IF opcode(7 downto 0)="11111111" AND cpu(1)='1' THEN
							next_micro_state <= bsr2;
							set(longaktion) <= '1';
						ELSIF opcode(7 downto 0)="00000000" THEN
							next_micro_state <= bsr2;
						ELSE	
							next_micro_state <= bsr1;
							setstate <= "11";
							writePC <= '1';
						END IF;
					ELSE									--bra
						IF opcode(7 downto 0)="11111111" AND cpu(1)='1' THEN
							next_micro_state <= bra1;
							set(longaktion) <= '1';
						ELSIF opcode(7 downto 0)="00000000" THEN
							next_micro_state <= bra1;
						ELSE
							setstate <= "01";
							next_micro_state <= bra1;
						END IF;
					END IF;
				END IF;	
				
-- 0111 ----------------------------------------------------------------------------		
			WHEN "0111" =>				--moveq
				IF opcode(8)='0' THEN
					datatype <= "10";		--Long
					set_exec(Regwrena) <= '1';
					set_exec(opcMOVEQ) <= '1';
					set_exec(opcMOVE) <= '1';
					dest_hbits <= '1';
				ELSE
					trap_illegal <= '1';
					trapmake <= '1';
				END IF;
				
---- 1000 ----------------------------------------------------------------------------		
			WHEN "1000" => 								--or	
				IF opcode(7 downto 6)="11" THEN	--divu, divs
					IF DIV_Mode/=3 AND
					   opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --ea illegal modes
						IF opcode(5 downto 4)="00" THEN	--Dn, An
							regdirectsource <= '1';
						END IF;
						IF (micro_state=idle AND nextpass='1') OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
							setstate <="01";
							next_micro_state <= div1;
						END IF;
						ea_build_now <= '1';
						IF z_error='0' AND set_V_Flag='0' THEN
							set_exec(Regwrena) <= '1';
						END IF;
							source_lowbits <='1';
						IF nextpass='1' OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
							dest_hbits <= '1';
						END IF;
						datatype <= "01";
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(8)='1' AND opcode(5 downto 4)="00" THEN	--sbcd, pack , unpack
					IF opcode(7 downto 6)="00" THEN	--sbcd
						build_bcd <= '1';
						set_exec(opcADD) <= '1';
						set_exec(opcSBCD) <= '1';
						set(addsub) <= '1';
					ELSIF opcode(7 downto 6)="01" OR opcode(7 downto 6)="10" THEN	--pack , unpack
						set_exec(ea_data_OP1) <= '1';
						set(no_Flags) <= '1';
						source_lowbits <='1';
						IF opcode(7 downto 6) = "01" THEN	--pack
							set_exec(opcPACK) <= '1';
							datatype <= "01";				--Word
						ELSE								--unpk
							set_exec(opcUNPACK) <= '1';
							datatype <= "00";				--Byte
						END IF;
						IF opcode(3)='0' THEN
							IF opcode(7 downto 6) = "01" THEN	--pack
								set_datatype <= "00";		--Byte
							ELSE								--unpk
								set_datatype <= "01";		--Word
							END IF;
							set_exec(Regwrena) <= '1';
							dest_hbits <= '1';
							IF decodeOPC='1' THEN
								next_micro_state <= nop;
--								set_direct_data <= '1';
								set(store_ea_packdata) <= '1';
								set(store_ea_data) <= '1';
							END IF;
						ELSE				-- pack -(Ax),-(Ay)
							write_back <= '1';
							IF decodeOPC='1' THEN
								next_micro_state <= pack1;
								set_direct_data <= '1';
							END IF;
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSE									--or
					IF opcode(7 downto 6)/="11" AND --illegal opmode
					   ((opcode(8)='0' AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) OR --illegal src ea
					   (opcode(8)='1' AND opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) THEN --illegal dst ea
						set_exec(opcOR) <= '1';
						build_logical <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				END IF;
				
---- 1001, 1101 -----------------------------------------------------------------------		
			WHEN "1001"|"1101" => 						--sub, add
				IF opcode(8 downto 3)/="000001" AND --byte src address reg direct
				   (((opcode(8)='0' OR opcode(7 downto 6)="11") AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) OR --illegal src ea
				   (opcode(8)='1' AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) THEN --illegal dst ea
					set_exec(opcADD) <= '1';
					ea_build_now <= '1';
					IF opcode(14)='0' THEN
						set(addsub) <= '1';
					END IF;
					IF opcode(7 downto 6)="11" THEN	--	--adda, suba
						IF opcode(8)='0' THEN	--adda.w, suba.w
							datatype <= "01";	--Word
						END IF;
						set_exec(Regwrena) <= '1';
						source_lowbits <='1';
						IF opcode(3)='1' THEN
							source_areg <= '1';
						END IF;
						set(no_Flags) <= '1';
						IF setexecOPC='1' THEN
							dest_areg <='1';
							dest_hbits <= '1';
						END IF;
					ELSE
						IF opcode(8)='1' AND opcode(5 downto 4)="00" THEN		--addx, subx
							build_bcd <= '1';
						ELSE							--sub, add
							build_logical <= '1';
						END IF;
					END IF;
				ELSE
						trap_illegal <= '1';
						trapmake <= '1';
				END IF;
--				
---- 1010 ----------------------------------------------------------------------------		
			WHEN "1010" => 							--Trap 1010
				trap_1010 <= '1';
				trapmake <= '1';
---- 1011 ----------------------------------------------------------------------------		
			WHEN "1011" => 							--eor, cmp
				IF opcode(7 downto 6)="11" THEN	--CMPA
					IF opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00" THEN --illegal src ea
						ea_build_now <= '1';
						IF opcode(8)='0' THEN	--cmpa.w
							datatype <= "01";	--Word
							set_exec(opcCPMAW) <= '1';
						END IF;
						set_exec(opcCMP) <= '1';
						IF setexecOPC='1' THEN
							source_lowbits <='1';
							IF opcode(3)='1' THEN
								source_areg <= '1';
							END IF;
							dest_areg <='1';
							dest_hbits <= '1';
						END IF;
						set(addsub) <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSE	--cmpm, eor, cmp
					IF opcode(8)='1' THEN
						IF opcode(5 downto 3)="001" THEN		--cmpm
							ea_build_now <= '1';
							set_exec(opcCMP) <= '1';
							IF decodeOPC='1' THEN
								IF opcode(2 downto 0)="111" THEN
									set(use_SP) <= '1';
								END IF;
								setstate <= "10";
								set(update_ld) <= '1';
								set(postadd) <= '1';
								next_micro_state <= cmpm;
							END IF;
							set_exec(ea_data_OP1) <= '1';
							set(addsub) <= '1';
						ELSE						--EOR
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" THEN --illegal dst ea
								ea_build_now <= '1';
								build_logical <= '1';
								set_exec(opcEOR) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
					ELSE							--CMP
						IF opcode(8 downto 3)/="000001" AND --byte src address reg direct
						   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --illegal src ea
							ea_build_now <= '1';
							build_logical <= '1';
							set_exec(opcCMP) <= '1';
							set(addsub) <= '1';
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
				END IF;
--				
---- 1100 ----------------------------------------------------------------------------		
			WHEN "1100" => 								--and, exg
				IF opcode(7 downto 6)="11" THEN	--mulu, muls
					IF MUL_Mode/=3 AND
					   opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN --ea illegal modes
						IF opcode(5 downto 4)="00" THEN	--Dn, An
							regdirectsource <= '1';
						END IF;
						IF (micro_state=idle AND nextpass='1') OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN	
							IF MUL_Hardware=0 THEN
								setstate <="01";
								set(ld_rot_cnt) <= '1';
								next_micro_state <= mul1;
							ELSE
								set_exec(write_lowlong) <= '1';
								set_exec(opcMULU) <= '1';
							END IF;
						END IF;
						ea_build_now <= '1';
						set_exec(Regwrena) <= '1';
						source_lowbits <='1';
						IF (nextpass='1') OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
							dest_hbits <= '1';
						END IF;
						datatype <= "01";
						IF setexecOPC='1' THEN
							datatype <= "10";
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(8)='1' AND opcode(5 downto 4)="00" THEN	--exg, abcd
					IF opcode(7 downto 6)="00" THEN	--abcd
						build_bcd <= '1';
						set_exec(opcADD) <= '1';
						set_exec(opcABCD) <= '1';
					ELSE									--exg
						IF opcode(7 downto 4)="0100" OR opcode(7 downto 3)="10001" THEN
							datatype <= "10";
							set(Regwrena) <= '1';
							set(exg) <= '1';
							set(alu_move) <= '1';
							IF opcode(6)='1' AND opcode(3)='1' THEN
								dest_areg <= '1';
								source_areg <= '1';
							END IF;
							IF decodeOPC='1' THEN
								setstate <= "01";
							ELSE
								dest_hbits <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
				ELSE									--and
					IF opcode(7 downto 6)/="11" AND --illegal opmode
					   ((opcode(8)='0' AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) OR --illegal src ea
					   (opcode(8)='1' AND opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) THEN --illegal dst ea
						set_exec(opcAND) <= '1';
						build_logical <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				END IF;
--				
---- 1110 ----------------------------------------------------------------------------		
			WHEN "1110" => 								--rotation / bitfield
				IF opcode(7 downto 6)="11" THEN
					IF opcode(11)='0' THEN
					   IF (opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN --ea illegal modes
							IF BarrelShifter=0 THEN
								set_exec(opcROT) <= '1';
							ELSE
								set_exec(exec_BS) <='1';
							END IF;
							ea_build_now <= '1';
							datatype <= "01";
							set_rot_bits <= opcode(10 downto 9);
							set_exec(ea_data_OP1) <= '1';
							write_back <= '1';
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE		--bitfield
						IF BitField=0 OR (cpu(1)='0' AND BitField=2) OR
						   ((opcode(10 downto 9)="11" OR opcode(10 downto 8)="010" OR opcode(10 downto 8)="100") AND
						   (opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" OR (opcode(5 downto 3)="111" AND opcode(2 downto 1)/="00"))) OR
						   ((opcode(10 downto 9)="00" OR opcode(10 downto 8)="011" OR opcode(10 downto 8)="101") AND
						   (opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" OR opcode(5 downto 2)="1111")) THEN
							trap_illegal <= '1';
							trapmake <= '1';
						ELSE
							IF decodeOPC='1' THEN
								next_micro_state <= nop;
								set(get_2ndOPC) <= '1';
								set(ea_build) <= '1';
							END IF;
							set_exec(opcBF) <= '1';
--		000-bftst, 001-bfextu, 010-bfchg, 011-bfexts, 100-bfclr, 101-bfff0, 110-bfset, 111-bfins								
							IF opcode(10)='1' OR opcode(8)='0' THEN
								set_exec(opcBFwb) <= '1';			--'1' for tst,chg,clr,ffo,set,ins    --'0' for extu,exts
							END IF;
							IF opcode(10 downto 8)="111" THEN	--BFINS
								set_exec(ea_data_OP1) <= '1';
							END IF;
							IF opcode(10 downto 8)="010" OR opcode(10 downto 8)="100" OR opcode(10 downto 8)="110" OR opcode(10 downto 8)="111" THEN
								write_back <= '1';
							END IF;
							ea_only <= '1';
							IF opcode(10 downto 8)="001" OR opcode(10 downto 8)="011" OR opcode(10 downto 8)="101" THEN
								set_exec(Regwrena) <= '1';
							END IF;
							IF opcode(4 downto 3)="00" THEN
								IF opcode(10 downto 8)/="000" THEN
									set_exec(Regwrena) <= '1';
								END IF;
								IF exec(ea_build)='1' THEN
									dest_2ndHbits <= '1';
									source_2ndLbits <= '1';
									set(get_bfoffset) <='1';
									setstate <= "01";
								END IF;
							END IF;
							IF set(get_ea_now)='1' THEN
								setstate <= "01";
							END IF;
							IF exec(get_ea_now)='1' THEN
								dest_2ndHbits <= '1';
								source_2ndLbits <= '1';
								set(get_bfoffset) <='1';
								setstate <= "01";
								set(mem_addsub) <='1';
								next_micro_state <= bf1;
							END IF;
							IF setexecOPC='1' THEN
								IF opcode(10 downto 8)="111" THEN	--BFINS
									source_2ndHbits <= '1';
								ELSE
									source_lowbits <= '1';
								END IF;
								IF opcode(10 downto 8)="001" OR opcode(10 downto 8)="011" OR opcode(10 downto 8)="101" THEN	--BFEXT, BFFFO
									dest_2ndHbits <= '1';
								END IF;
							END IF;
						END IF;
					END IF;
				ELSE
					data_is_source <= '1';
					IF BarrelShifter=0 OR (cpu(1)='0' AND BarrelShifter=2) THEN
						set_exec(opcROT) <= '1';
						set_rot_bits <= opcode(4 downto 3);
						set_exec(Regwrena) <= '1';
						IF decodeOPC='1' THEN
							IF opcode(5)='1' THEN
								next_micro_state <= rota1;
								set(ld_rot_cnt) <= '1';
								setstate <= "01";
							ELSE
								set_rot_cnt(2 downto 0) <= opcode(11 downto 9);
								IF opcode(11 downto 9)="000" THEN
									set_rot_cnt(3) <='1';
								ELSE
									set_rot_cnt(3) <='0';
								END IF;
							END IF;
						END IF;
					ELSE
						set_exec(exec_BS) <='1';
						set_rot_bits <= opcode(4 downto 3);
						set_exec(Regwrena) <= '1';
					END IF;
				END IF;
--				
---- 1111 ----------------------------------------------------------------------------		
			WHEN "1111" =>
				-- 68040 instructions outside the FPU (M68040 User's Manual, M68000
				-- PRM): the core has no caches and no MMU, so CINV, CPUSH,
				-- PFLUSH and PTEST only check the privilege (PTEST leaves MMUSR
				-- alone); scope 00 of CINV and CPUSH is not an instruction
				IF cpu040='1' AND opcode(11 downto 9)="001" THEN			--FPU (coprocessor 1)
					IF fpu_fbcc='1' AND fpu_fbx='1' THEN
						-- FBcc with an exception pending, or a signaling predicate on a
						-- NaN with BSUN enabled: the pre-instruction exception
						trap_fpx <= '1';
						trapmake <= '1';
					ELSIF fpu_fbcc='1' THEN
						-- FBcc: Bcc.W or Bcc.L with the condition of the FPCC
						datatype <= "10";
						IF micro_state=idle THEN
							next_micro_state <= bra1;
							IF opcode(6)='1' THEN
								set(longaktion) <= '1';
							END IF;
						END IF;
					ELSIF fpu_ins='0' THEN
						-- FSAVE/FRESTORE-like encodings that are not instructions
						trap_1111 <= '1';
						trapmake <= '1';
					ELSIF opcode(8)='1' AND SVmode='0' THEN
						trap_priv <= '1';						-- FSAVE, FRESTORE
						trapmake <= '1';
					ELSE
						IF fpu_memea='1' THEN
							-- the kernel's effective address modes, as PEA builds them;
							-- after a command word one cycle later, as CAS2 does
							ea_only <= '1';
							datatype <= "10";
							IF decodeOPC='1' THEN
								IF fpu_gen='1' THEN
									set(ea_build) <= '1';
									next_micro_state <= nop;
								ELSE
									ea_build_now <= '1';
								END IF;
							END IF;
							IF set(get_ea_now)='1' THEN
								setstate <= "01";
							END IF;
							IF nextpass='1' AND micro_state=idle THEN
								setstate <= "01";
								next_micro_state <= fpu_go;
							END IF;
						ELSIF decodeOPC='1' THEN
							setstate <= "01";
							next_micro_state <= fpu_go;
						END IF;
					END IF;
				ELSIF cpu040='1' AND opcode(11 downto 8)="0100" THEN		--CINV, CPUSH
					IF opcode(4 downto 3)="00" THEN
						trap_1111 <= '1';
						trapmake <= '1';
					ELSIF SVmode='0' THEN
						trap_priv <= '1';
						trapmake <= '1';
					END IF;
				ELSIF cpu040='1' AND (opcode(11 downto 5)="0101000" OR
				      (opcode(11 downto 6)="010101" AND opcode(4 downto 3)="01")) THEN	--PFLUSH, PTEST
					IF SVmode='0' THEN
						trap_priv <= '1';
						trapmake <= '1';
					ELSIF decodeOPC='1' AND opcode(6)='1' THEN
						setstate <= "01";
						next_micro_state <= mmu_ptest1;		-- PTEST (An)
					ELSIF decodeOPC='1' AND opcode(5)='0' THEN
						setstate <= "01";
						next_micro_state <= pflush1;		-- PFLUSH
					END IF;
				ELSIF cpu040='1' AND (opcode(11 downto 3)="011000100" OR opcode(11 downto 5)="0110000") THEN	--MOVE16
					-- (Ax)+,(Ay)+ has its extension word in sndOPC after the
					-- decode; the absolute forms fetch the low address word in
					-- m16_abs. Not privileged.
					IF decodeOPC='1' THEN
						IF opcode(5)='1' THEN
							setstate <= "01";
							next_micro_state <= m16_go;
						ELSE
							next_micro_state <= m16_abs;
						END IF;
					END IF;
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="100" THEN --cpSAVE
					IF opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="011" AND
					   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN --ea illegal modes
						IF opcode(11 downto 9)/="000" THEN
							IF SVmode='1' THEN
								IF opcode(5)='0' AND opcode(5 downto 4)/="01" THEN
									--never reached according to cputest?!
									--cpSAVE not implemented
									trap_illegal <= '1';
									trapmake <= '1';
								ELSE
									trap_1111 <= '1';
									trapmake <= '1';
								END IF;
							ELSE
								trap_priv <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							IF SVmode='1' THEN
								trap_1111 <= '1';
								trapmake <= '1';
							ELSE
								trap_priv <= '1';
								trapmake <= '1';
							END IF;
						END IF;
					ELSE
						trap_1111 <= '1';
						trapmake <= '1';
					END IF;
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="101" THEN --cpRESTORE
					IF opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="100" AND
					   (opcode(5 downto 3)/="111" OR (opcode(2 downto 1)/="11" AND
					   opcode(2 downto 0)/="101")) THEN --ea illegal modes
						IF opcode(5 downto 1)/="11110" THEN
							IF opcode(11 downto 9)="001" OR opcode(11 downto 9)="010" THEN
								IF SVmode='1' THEN
									-- With no coprocessor every cpRESTORE takes Line-F, as the
									-- other modes already did; d16(An) used to give ILLEGAL
									-- ("cpRESTORE not implemented")
									trap_1111 <= '1';
									trapmake <= '1';
								ELSE
									trap_priv <= '1';
									trapmake <= '1';
								END IF;
							ELSE
								IF SVmode='1' THEN
									trap_1111 <= '1';
									trapmake <= '1';
								ELSE
									trap_priv <= '1';
									trapmake <= '1';
								END IF;
							END IF;
						ELSE
							trap_1111 <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						trap_1111 <= '1';
						trapmake <= '1';
					END IF;
				ELSE
					trap_1111 <= '1';
					trapmake <= '1';
				END IF;
--							
----      ----------------------------------------------------------------------------		
			WHEN OTHERS =>
				trap_illegal <= '1';
				trapmake <= '1';

		END CASE;

-- use for AND, OR, EOR, CMP
		IF build_logical='1' THEN
			ea_build_now <= '1';
			IF set_exec(opcCMP)='0' AND (opcode(8)='0' OR opcode(5 downto 4)="00" ) THEN					
				set_exec(Regwrena) <= '1';
			END IF;
			IF opcode(8)='1' THEN
				write_back <= '1';
				set_exec(ea_data_OP1) <= '1';
			ELSE
				source_lowbits <='1';
				IF opcode(3)='1' THEN		--use for cmp
					source_areg <= '1';
				END IF;
				IF setexecOPC='1' THEN
					dest_hbits <= '1';
				END IF;
			END IF;
		END IF;
		
-- use for ABCD, SBCD
		IF build_bcd='1' THEN
			set_exec(use_XZFlag) <= '1';
			set_exec(ea_data_OP1) <= '1';
			write_back <= '1';
			source_lowbits <='1';
			IF opcode(3)='1' THEN
				IF decodeOPC='1' THEN
					IF opcode(2 downto 0)="111" THEN
						set(use_SP) <= '1';
					END IF;
					setstate <= "10";
					set(update_ld) <= '1';
					set(presub) <= '1';
					next_micro_state <= op_AxAy;
					dest_areg <= '1';				--???
				END IF;
			ELSE
				dest_hbits <= '1';
				set_exec(Regwrena) <= '1';
			END IF;
		END IF;
		

------------------------------------------------------------------------------		
------------------------------------------------------------------------------		
		IF set_Z_error='1'  THEN		-- divu by zero
			trapmake <= '1';			--wichtig for USP
			IF trapd='0' THEN
				writePC <= '1';
			END IF;			
		END IF;	
		
-----------------------------------------------------------------------------
-- execute microcode
-----------------------------------------------------------------------------
		IF rising_edge(clk) THEN
	        IF Reset='1' THEN
				micro_state <= ld_nn;
				thr_pass <= '0';
			ELSIF clkena_lw='1' THEN
				trapd <= trapmake;
				IF micro_state=thr0 THEN
					thr_pass <= '1';
				ELSIF micro_state=trap3 THEN
					thr_pass <= '0';
				END IF;
				IF xc_now='1' THEN
					micro_state <= ae_fix1;		-- address or access error: then the frame
				ELSE
					micro_state <= next_micro_state;
				END IF;
			END IF;
		END IF;

			CASE micro_state IS
				WHEN ld_nn =>		-- (nnnn).w/l=>
					set(get_ea_now) <='1';
					setnextpass <= '1';
					set(addrlong) <= '1';
					
				WHEN st_nn =>		-- =>(nnnn).w/l
					setstate <= "11";
					set(addrlong) <= '1';
					next_micro_state <= nop;
					
				WHEN ld_dAn1 =>		-- d(An)=>, --d(PC)=>
					set(get_ea_now) <='1';
					setdisp <= '1';		--word
					setnextpass <= '1';
					
				WHEN ld_AnXn1 =>		-- d(An,Xn)=>, --d(PC,Xn)=>
					IF brief(8)='0' OR extAddr_Mode=0 OR (cpu(1)='0' AND extAddr_Mode=2) THEN
						setdisp <= '1';		--byte	
						setdispbyte <= '1';
						setstate <= "01";
						set(briefext) <= '1';
						next_micro_state <= ld_AnXn2;
					ELSE	
						IF brief(7)='1'THEN		--suppress Base
							set_suppress_base <= '1';
						ELSIF exec(dispouter)='1' THEN
							set(dispouter) <= '1';
						END IF;
						IF brief(5)='0' THEN --NULL Base Displacement
							setstate <= "01";
						ELSE  --WORD Base Displacement
							IF brief(4)='1' THEN
								set(longaktion) <= '1'; --LONG Base Displacement
							END IF;
						END IF;
						next_micro_state <= ld_229_1;
					END IF;
					
				WHEN ld_AnXn2 =>
					set(get_ea_now) <='1';
					setdisp <= '1';		--brief
					setnextpass <= '1';
					
-------------------------------------------------------------------------------------					
					
				WHEN ld_229_1 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					IF brief(5)='1' THEN    --Base Displacement
						setdisp <= '1';		--add last_data_read
					END IF;
					IF brief(6)='0' AND brief(2)='0' THEN --Preindex or Index
						set(briefext) <= '1';
						setstate <= "01";
						IF brief(1 downto 0)="00" THEN
							next_micro_state <= ld_AnXn2;
						ELSE	
							next_micro_state <= ld_229_2;
						END IF;	
					ELSE
						IF brief(1 downto 0)="00" THEN
							set(get_ea_now) <='1';
							setnextpass <= '1';
						ELSE
							setstate <= "10";
							setaddrvalue <= '1';
							set(longaktion) <= '1';
							next_micro_state <= ld_229_3;
						END IF;
					END IF;
					
				WHEN ld_229_2 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					setdisp <= '1';		-- add Index
					setstate <= "10";
					setaddrvalue <= '1';
					set(longaktion) <= '1';
					next_micro_state <= ld_229_3;
				
				WHEN ld_229_3 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					set_suppress_base <= '1';
					set(dispouter) <= '1'; 	
					IF brief(1)='0' THEN --NULL Outer Displacement
						setstate <= "01";
					ELSE  --WORD Outer Displacement
						IF brief(0)='1' THEN
							set(longaktion) <= '1'; --LONG Outer Displacement
						END IF;
					END IF;
					next_micro_state <= ld_229_4;
				
				WHEN ld_229_4 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					IF brief(1)='1' THEN  -- Outer Displacement
						setdisp <= '1';	  --add last_data_read
					END IF;
					IF brief(6)='0' AND brief(2)='1' THEN --Postindex
						set(briefext) <= '1';
						setstate <= "01";
						next_micro_state <= ld_AnXn2;
					ELSE
						set(get_ea_now) <='1';
						setnextpass <= '1';
					END IF;
					
----------------------------------------------------------------------------------------				
				WHEN st_dAn1 =>		-- =>d(An)
					setstate <= "11";
					setdisp <= '1';		--word
					next_micro_state <= nop;
					
				WHEN st_AnXn1 =>		-- =>d(An,Xn)
					IF brief(8)='0' OR extAddr_Mode=0 OR (cpu(1)='0' AND extAddr_Mode=2) THEN
						setdisp <= '1';		--byte	
						setdispbyte <= '1';
						setstate <= "01";
						set(briefext) <= '1';
						next_micro_state <= st_AnXn2;
					ELSE	
						IF brief(7)='1'THEN		--suppress Base
							set_suppress_base <= '1';
--						ELSIF exec(dispouter)='1' THEN
--							set(dispouter) <= '1';
						END IF;
						IF brief(5)='0' THEN --NULL Base Displacement
							setstate <= "01";
						ELSE  --WORD Base Displacement
							IF brief(4)='1' THEN
								set(longaktion) <= '1'; --LONG Base Displacement
							END IF;
						END IF;
						next_micro_state <= st_229_1;
					END IF;
					
				WHEN st_AnXn2 =>
					setstate <= "11";
					setdisp <= '1';		--brief	
					set(hold_dwr) <= '1';
					next_micro_state <= nop;
					
-------------------------------------------------------------------------------------					
					
				WHEN st_229_1 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					IF brief(5)='1' THEN    --Base Displacement
						setdisp <= '1';		--add last_data_read
					END IF;
					IF brief(6)='0' AND brief(2)='0' THEN --Preindex or Index
						set(briefext) <= '1';
						setstate <= "01";
						IF brief(1 downto 0)="00" THEN
							next_micro_state <= st_AnXn2;
						ELSE	
							next_micro_state <= st_229_2;
						END IF;	
					ELSE
						IF brief(1 downto 0)="00" THEN
							setstate <= "11";
							next_micro_state <= nop;
						ELSE
							set(hold_dwr) <= '1';
							setstate <= "10";
							set(longaktion) <= '1';
							next_micro_state <= st_229_3;
						END IF;
					END IF;
					
				WHEN st_229_2 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					setdisp <= '1';		-- add Index
					set(hold_dwr) <= '1';
					setstate <= "10";
					set(longaktion) <= '1';
					next_micro_state <= st_229_3;
				
				WHEN st_229_3 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					set(hold_dwr) <= '1';
					set_suppress_base <= '1';
					set(dispouter) <= '1'; 	
					IF brief(1)='0' THEN --NULL Outer Displacement
						setstate <= "01";
					ELSE  --WORD Outer Displacement
						IF brief(0)='1' THEN
							set(longaktion) <= '1'; --LONG Outer Displacement
						END IF;
					END IF;
					next_micro_state <= st_229_4;
				
				WHEN st_229_4 =>		-- (bd,An,Xn)=>, --(bd,PC,Xn)=>
					set(hold_dwr) <= '1';
					IF brief(1)='1' THEN  -- Outer Displacement
						setdisp <= '1';	  --add last_data_read
					END IF;
					IF brief(6)='0' AND brief(2)='1' THEN --Postindex
						set(briefext) <= '1';
						setstate <= "01";
						next_micro_state <= st_AnXn2;
					ELSE
						setstate <= "11";
						next_micro_state <= nop;
					END IF;
					
----------------------------------------------------------------------------------------				
				WHEN bra1 =>		--bra
					IF exe_condition='1' THEN
						TG68_PC_brw <= '1';	--pc+0000
						next_micro_state <= nop;
						if long_start='0' then
							skipFetch_i <= '1'; -- AMR/GS - can't skip fetch for bra.l
						end if;
					END IF;
					
				WHEN bsr1 =>		--bsr short
					TG68_PC_brw <= '1';	
					next_micro_state <= nop;
					
				WHEN bsr2 =>		--bsr
					IF long_start='0' THEN	
						TG68_PC_brw <= '1';	
						skipFetch_i <= '1';	-- AMR - can't skip fetch for bsr.l
					END IF;
					set(longaktion) <= '1';
					writePC <= '1';
					setstate <= "11";
					next_micro_state <= nopnop;
					setstackaddr <='1';
				WHEN nopnop =>		--bsr
					next_micro_state <= nop;

				WHEN dbcc1 =>		--dbcc
					IF exe_condition='0' THEN
						Regwrena_now <= '1';
						IF c_out(1)='1' THEN
							skipFetch_i <= '1';				
							next_micro_state <= nop;
							TG68_PC_brw <= '1';	
						END IF;	
					END IF;

				WHEN chk20 =>			--if C is set -> signed compare
					set(ea_data_OP1) <= '1';
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(alu_setFlags) <= '1';
					setstate <="01";
					next_micro_state <= chk21;
				WHEN chk21 =>			-- check lower bound
					dest_2ndHbits <= '1';
					IF sndOPC(15)='1' THEN
						set_datatype <="10";	--long
						dest_LDRareg <= '1';
						IF opcode(10 downto 9)="00" THEN
							set(opcEXTB) <= '1';
						END IF;
					END IF;
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(alu_setFlags) <= '1';
					setstate <="01";
					next_micro_state <= chk22;
				WHEN chk22 =>			--check upper bound
					dest_2ndHbits <= '1';
					set(ea_data_OP2) <= '1';
					IF sndOPC(15)='1' THEN
						set_datatype <="10";	--long
						dest_LDRareg <= '1';
					END IF;
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(opcCHK2) <= '1';
					set(opcEXTB) <= exec(opcEXTB);
					IF sndOPC(11)='1' THEN
						setstate <="01";
						next_micro_state <= chk23;
					END IF;
				WHEN chk23 =>
						setstate <="01";
						next_micro_state <= chk24;
				WHEN chk24 =>
					IF Flags(0)='1'THEN
						trapmake <= '1';
					END IF;
					
					
				WHEN cas1 =>
						setstate <="01";
						next_micro_state <= cas2;
				WHEN cas2 =>
					source_2ndMbits <= '1';
					IF Flags(2)='1'THEN
						setstate<="11";
						set(write_reg) <= '1';
						set(restore_ADDR) <= '1';
						next_micro_state <= nop;
					ELSE
						set(Regwrena) <= '1';
						set(ea_data_OP2) <='1';
						dest_2ndLbits <= '1';
						set(alu_move) <= '1';
					END IF;
					
				WHEN cas21 =>
					dest_2ndHbits <= '1';
					dest_LDRareg <= sndOPC(15);
					set(get_ea_now) <='1';
					next_micro_state <= cas22;
				WHEN cas22 =>
					setstate <= "01";
					source_2ndLbits <= '1';
					set(ea_data_OP1) <= '1';
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(alu_setFlags) <= '1';
					next_micro_state <= cas23;
				WHEN cas23 =>
					dest_LDRHbits <= '1';
					set(get_ea_now) <='1';
					next_micro_state <= cas24;
				WHEN cas24 =>
					IF Flags(2)='1'THEN
						set(alu_setFlags) <= '1';
					END IF;
					setstate <="01";
					set(hold_dwr) <= '1';
					source_LDRLbits <= '1';
					set(ea_data_OP1) <= '1';
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					next_micro_state <= cas25;
				WHEN cas25 =>
					setstate <= "01";
					set(hold_dwr) <= '1';
					next_micro_state <= cas26;
				WHEN cas26 =>
					IF Flags(2)='1'THEN -- write Update 1 to Destination 1
						source_2ndMbits <= '1';
						set(write_reg) <= '1';
						dest_2ndHbits <= '1';
						dest_LDRareg <= sndOPC(15);
						setstate <= "11";
						set(get_ea_now) <='1';
						next_micro_state <= cas27;
					ELSE		   			-- write Destination 2 to Compare 2 first
						set(hold_dwr) <= '1';
						set(hold_OP2) <='1';
						dest_LDRLbits <= '1';
						set(alu_move) <= '1';
						set(Regwrena) <= '1';
						set(ea_data_OP2) <='1';
						next_micro_state <= cas28;
					END IF;
				WHEN cas27 =>				-- write Update 2 to Destination 2
					source_LDRMbits <= '1';
					set(write_reg) <= '1';
					dest_LDRHbits <= '1';
					setstate <= "11";
					set(get_ea_now) <='1';
					next_micro_state <= nopnop;
				WHEN cas28 =>				-- write Destination 1 to Compare 1 second
					dest_2ndLbits <= '1';
					set(alu_move) <= '1';
					set(Regwrena) <= '1';
					
				WHEN movem1 =>		--movem
					IF last_data_read(15 downto 0)/=X"0000" THEN
						setstate <="01";
						IF opcode(5 downto 3)="100" THEN
							set(mem_addsub) <= '1';
							IF cpu(1)='1' THEN
								set(Regwrena) <= '1';	--tg
							END IF;
						END IF;
						next_micro_state <= movem2;
					END IF;
				WHEN movem2 =>		--movem
					IF movem_run='0' THEN
						setstate <="01";
					ELSE	
						set(movem_action) <= '1';
						set(mem_addsub) <= '1';
						next_micro_state <= movem2;
						IF opcode(10)='0' THEN
							setstate <="11";
							set(write_reg) <= '1';
						ELSE
							setstate <="10";
						END IF;
					END IF;	

				WHEN andi =>		--andi
					IF opcode(5 downto 4)/="00" THEN
						setnextpass <= '1';
					END IF;

				WHEN pack1 =>		-- pack -(Ax),-(Ay)
					IF opcode(2 downto 0)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set(hold_ea_data) <= '1';	
					set(update_ld) <= '1';
					setstate <= "10";
					set(presub) <= '1';
					next_micro_state <= pack2;
					dest_areg <= '1';				
				WHEN pack2 =>	
					IF opcode(11 downto 9)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set(hold_ea_data) <= '1';	
					set_direct_data <= '1';
					IF opcode(7 downto 6) = "01" THEN	--pack
						datatype <= "00";		--Byte
					ELSE								--unpk
						datatype <= "01";		--Word
					END IF;
					set(presub) <= '1';
					dest_hbits <= '1'; 
					dest_areg <= '1';
					setstate <= "10";
					next_micro_state <= pack3;
				WHEN pack3 =>	
					skipFetch_i <= '1';
					
				WHEN op_AxAy =>		-- op -(Ax),-(Ay)
					IF opcode(11 downto 9)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set_direct_data <= '1';
					set(presub) <= '1';
					dest_hbits <= '1'; 
					dest_areg <= '1';
					setstate <= "10";

				WHEN cmpm =>		-- cmpm (Ay)+,(Ax)+
					IF opcode(11 downto 9)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set_direct_data <= '1';
					set(postadd) <= '1';
					dest_hbits <= '1'; 
					dest_areg <= '1';
					setstate <= "10";
					
				WHEN link1 =>		-- link
					setstate <="11";
					source_areg <= '1';
					set(opcMOVE) <= '1';
					set(Regwrena) <= '1';
					next_micro_state <= link2;
				WHEN link2 =>		-- link
					setstackaddr <='1';
					set(ea_data_OP2) <= '1';
					
				WHEN unlink1 =>		-- unlink
					setstate <="10";
					setstackaddr <='1';
					set(postadd) <= '1';
					next_micro_state <= unlink2;
				WHEN unlink2 =>		-- unlink
					set(ea_data_OP2) <= '1';
					
-- paste and copy form TH	---------	
				WHEN trap00 =>          -- TRAP format #2
					next_micro_state <= trap0;
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "10";
------------------------------------
				WHEN trap0 =>		-- TRAP
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					IF use_VBR_Stackframe='1' THEN	--68010
						set(writePC_add) <= '1';
						datatype <= "01";
--						set_datatype <= "10";
						next_micro_state <= trap1;
					ELSE
						IF trap_interrupt='1' OR trap_trace='1' OR trap_berr='1' THEN
							writePC <= '1';
						END IF;
						datatype <= "10";
						next_micro_state <= trap2;
					END IF;

				WHEN trap1 =>		-- TRAP
					IF trap_interrupt='1' OR trap_trace='1' THEN
						writePC <= '1';
					END IF;
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "10";
					next_micro_state <= trap2;
				WHEN trap2 =>		-- TRAP
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "01";
					writeSR <= '1';
					IF trap_berr='1' OR (ae_frame='1' AND cpu="00") THEN
						next_micro_state <= trap4;
					ELSIF trap_interrupt='1' AND FlagsSR(4)='1' AND cpu(1)='1' AND thr_pass='0' THEN
						next_micro_state <= thr0;
					ELSE
						next_micro_state <= trap3;
					END IF;
				WHEN thr0 =>		-- interrupt with M set (68020/68040 UM 8.4): the frame
									-- above went on the MSP; M is cleared, and a format $1
									-- throwaway frame, the same with S set, goes on the ISP
					setstate <= "01";
					next_micro_state <= trap0;
				WHEN trap3 =>		-- TRAP
					set_vectoraddr <= '1';
					datatype <= "10";
					set(direct_delta) <= '1';	
					set(directPC) <= '1';
					setstate <= "10";
					next_micro_state <= nopnop;
				WHEN trap4 =>		-- TRAP
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "01";
					writeSR <= '1';
					next_micro_state <= trap5;
				WHEN trap5 =>		-- TRAP
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "10";
					writeSR <= '1';
					next_micro_state <= trap6;
				WHEN trap6 =>		-- TRAP
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "01";
					writeSR <= '1';
					next_micro_state <= trap3;
					
										-- return from exception - RTE
										-- fetch PC and status register from stack
										-- 010+ fetches another word containing
										-- the 12 bit vector offset and the
										-- frame format. If the frame format is
										-- 2 another two words have to be taken
										-- from the stack
				WHEN rte1 =>		-- RTE
					datatype <= "10";
					setstate <= "10";
					set(postadd) <= '1';
					setstackaddr <= '1';
					set(directPC) <= '1';	
					IF use_VBR_Stackframe='0' OR opcode(2)='1' THEN	--opcode(2)='1' => opcode is RTR
						set(update_FC) <= '1';
						set(direct_delta) <= '1';	
					END IF;
					next_micro_state <= rte2;
				WHEN rte2 =>		-- RTE
					datatype <= "01";
					set(update_FC) <= '1';
					IF use_VBR_Stackframe='1' AND opcode(2)='0' THEN
												-- 010+ reads another word
						setstate <= "10";
						set(postadd) <= '1';
						setstackaddr <= '1';
						next_micro_state <= rte3;
					ELSE
						next_micro_state <= nop;
					END IF;
--				WHEN rte3 =>			-- RTE
--					next_micro_state <= nop;
----					set(update_FC) <= '1';
-- paste and copy form TH	---------	
				when rte3 => -- RTE
					setstate <= "01"; -- idle state to wait
											-- for input data to
											-- arrive
					next_micro_state <= rte4;
				WHEN rte4 =>         -- RTE
											-- check for stack frame format #2
					-- formats the core can restore: $0, $2 (68020 and later) and
					-- $3 (68040, as long as $2); any other takes the format error
					if cpu(1)='1' and last_data_in(15 downto 12)="0001" then
						-- throwaway frame: its SR is loaded, the stack it selects is
						-- taken and the RTE starts again there
						setstate <= "01";
						next_micro_state <= rte_f1;
					elsif cpu040='1' and last_data_in(15 downto 12)="0111" then
						-- access error frame: no continuation is pending (the core sets
						-- no CP, CU, CT or CM), so the rest of the frame is dropped
						setstate <= "01";
						next_micro_state <= rte_f7;
					elsif last_data_in(15 downto 12)/="0000" and
					   not (cpu(1)='1' and last_data_in(15 downto 12)="0010") and
					   not (cpu040='1' and last_data_in(15 downto 12)="0011") then
						setstate <= "01";
						next_micro_state <= rte_ferr0;
					elsif last_data_in(15 downto 12)="0010" or last_data_in(15 downto 12)="0011" then
										  -- read another 32 bits in this case
						setstate <= "10"; -- read
						datatype <= "10"; -- long word
						set(postadd) <= '1';
						setstackaddr <= '1';
						next_micro_state <= rte5;
					else
						datatype <= "01";
						next_micro_state <= nop;
					end if;
				WHEN rte5 =>            -- RTE
					next_micro_state <= nop;
-------------------------------------

				WHEN rtd1 =>		-- RTD
					next_micro_state <= rtd2;
				WHEN rtd2 =>		-- RTD
					setstackaddr <= '1';
					set(Regwrena) <= '1';
					
				WHEN pflush1 =>		-- PFLUSH: the MMU flushes on this edge
					setstate <= "01";
					next_micro_state <= fpu_end;
				WHEN mmu_ptest1 =>	-- PTEST: the MMU starts on this edge
					setstate <= "01";
					next_micro_state <= mmu_ptest2;
				WHEN mmu_ptest2 =>
					setstate <= "01";
					IF mmu_ptest_done='1' THEN
						next_micro_state <= fpu_end;
					ELSE
						next_micro_state <= mmu_ptest2;
					END IF;
				WHEN rte_f1 =>		-- RTE of a format $1 frame: S and M of its SR take effect
					setstate <= "01";
					IF FlagsSR(5)/=preSVmode THEN
						set(changeMode) <= '1';
					END IF;
					next_micro_state <= rte_f1b;
				WHEN rte_f1b =>		-- and the RTE again, on that stack
					setstate <= "10";
					set(postadd) <= '1';
					setstackaddr <= '1';
					set(directSR) <= '1';
					next_micro_state <= rte1;
				WHEN rte_f7 =>		-- RTE of a format $7 frame: A7 + 52 worked out
					setstate <= "01";
					next_micro_state <= rte_f7b;
				WHEN rte_f7b =>		-- and written
					next_micro_state <= nop;
				WHEN rte_ferr0 =>	-- RTE format error: A7 - 8 worked out
					setstate <= "01";
					next_micro_state <= rte_ferr;
				WHEN rte_ferr =>	-- RTE format error: SP, SR and CCR back, then vector 14
					trap_fmt <= '1';
					trapmake <= '1';
				WHEN ae_fix1 =>		-- address error: the register correction is written
					setstate <= "01";
					IF acc_frame='1' THEN
						next_micro_state <= ae_push;	-- format $7
					ELSIF cpu040='1' THEN
						next_micro_state <= trap00;		-- format $2
					ELSIF cpu(0)='1' THEN
						next_micro_state <= ae_push;	-- format $8 or $A
					ELSE
						next_micro_state <= trap0;
					END IF;
				WHEN ae_push =>		-- address error, 68010 and 68020: one frame word
					set(presub) <= '1';
					setstackaddr <= '1';
					setstate <= "11";
					datatype <= "01";
					IF ae_cnt=0 THEN
						next_micro_state <= trap0;
					ELSE
						next_micro_state <= ae_push;
					END IF;
				WHEN fpu_go =>		-- FPU: TG68K_FPU starts on this edge
					setstate <= "01";
					IF fpu_gen='1' AND fpu_badcmd='1' THEN
						-- not an instruction (FScc/FDBcc: the condition word holds only
						-- a predicate 0-31): Line-F, left to the M68040FPSP; the FPU
						-- does not start
						trap_1111 <= '1';
						trapmake <= '1';
					ELSE
						next_micro_state <= fpu_wait;
					END IF;
				WHEN fpu_wait =>
					setstate <= "01";
					IF fpu_done='1' AND fpu_unimp='1' THEN
						-- unimplemented floating-point instruction: vector 11, format
						-- $2 (68040 UM 9.6); trapmake chooses trap00 (fpu_trap2)
						trap_1111 <= '1';
						trapmake <= '1';
					ELSIF fpu_done='1' AND fpu_xexc='1' THEN
						-- arithmetic exception: vectors 48-54, format $0 with the PC of
						-- the instruction, or $3 for FMOVE out (68040 UM 9.7)
						trap_fpx <= '1';
						trapmake <= '1';
					ELSIF fpu_done='1' AND fpu_unsupp='1' THEN
						-- unsupported data type (packed decimal): vector 55, format $0
						-- with the next instruction, or $3 with the effective address
						-- for FMOVE.P out (68040 UM 9.6.2)
						trap_unsupp <= '1';
						trapmake <= '1';
					ELSIF fpu_done='1' AND fpu_ftrap='1' THEN
						-- FTRAPcc taken: vector 7, format $2 as TRAPcc
						trap_trapv <= '1';
						trapmake <= '1';
					ELSIF fpu_done='1' THEN
						next_micro_state <= fpu_end;
					ELSE
						next_micro_state <= fpu_wait;
					END IF;
				WHEN fpu_end =>		-- go on at the next instruction (fpu_jump)
					setstate <= "00";
					next_micro_state <= nop;

				WHEN m16_abs =>		-- MOVE16: fetch the low word of the address
					setstate <= "01";
					next_micro_state <= m16_go;
				WHEN m16_go =>		-- MOVE16: the sequencer starts on this edge
					setstate <= "01";
					next_micro_state <= m16_wait;
				WHEN m16_wait =>
					setstate <= "01";
					IF m16_done='1' THEN
						next_micro_state <= m16_end;
					ELSE
						next_micro_state <= m16_wait;
					END IF;
				WHEN m16_end =>		-- fetch the next opcode
					setstate <= "00";
					next_micro_state <= nop;

				WHEN movec1 =>		-- MOVEC
					set(briefext) <= '1';
					set_writePCbig <='1';
					IF movec_ok='1' THEN
						IF opcode(0)='0' THEN
							set(Regwrena) <= '1';
						END IF;
--					ELSIF brief(11 downto 0)=X"800"OR brief(11 downto 0)=X"001" OR brief(11 downto 0)=X"000" THEN
--						trap_addr_error <= '1';
--						trapmake <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
					
				WHEN movep1 =>		-- MOVEP d(An)
					setdisp <= '1';	
					set(mem_addsub) <= '1';	
					set(mem_byte) <= '1';
					set(OP1addr) <= '1';		
					IF opcode(6)='1' THEN
						set(movepl) <= '1';
					END IF;
					IF opcode(7)='0' THEN
						setstate <= "10";
					ELSE
						setstate <= "11";
					END IF;
					next_micro_state <= movep2;
				WHEN movep2 =>		
					IF opcode(6)='1' THEN
						set(mem_addsub) <= '1';	
					    set(OP1addr) <= '1';		
					END IF;
					IF opcode(7)='0' THEN
						setstate <= "10";
					ELSE
						setstate <= "11";
					END IF;
					next_micro_state <= movep3;
				WHEN movep3 =>		
					IF opcode(6)='1' THEN
						set(mem_addsub) <= '1';	
					    set(OP1addr) <= '1';		
						set(mem_byte) <= '1';
						IF opcode(7)='0' THEN
							setstate <= "10";
						ELSE
							setstate <= "11";
						END IF;
						next_micro_state <= movep4;
					ELSE	
						datatype <= "01";		--Word
					END IF;
				WHEN movep4 =>		
					IF opcode(7)='0' THEN
						setstate <= "10";
					ELSE
						setstate <= "11";
					END IF;
					next_micro_state <= movep5;
				WHEN movep5 =>		
					datatype <= "10";		--Long
					
				WHEN mul1	=>		-- mulu
					IF opcode(15)='1' OR MUL_Mode=0 THEN
						set_rot_cnt <= "001110";
					ELSE
						set_rot_cnt <= "011110";
					END IF;
					setstate <="01";
					next_micro_state <= mul2;
				WHEN mul2	=>		-- mulu
					setstate <="01";
					IF rot_cnt="00001" THEN
						next_micro_state <= mul_end1;

					ELSE	
						next_micro_state <= mul2;
					END IF;
				WHEN mul_end1	=>		-- mulu
					IF opcode(15)='0' THEN
						set(hold_OP2) <= '1';
					END IF;
					datatype <= "10";
					set(opcMULU) <= '1';
					IF opcode(15)='0' AND (MUL_Mode=1 OR MUL_Mode=2) THEN
						dest_2ndHbits <= '1';
						set(write_lowlong) <= '1';
						IF sndOPC(10)='1' THEN
							setstate <="01";
							next_micro_state <= mul_end2;
						END IF;	
						set(Regwrena) <= '1';
					END IF;
					datatype <= "10";
				WHEN mul_end2	=>		-- divu
					dest_2ndLbits <= '1';
					set(write_reminder) <= '1';
					set(Regwrena) <= '1';
					set(opcMULU) <= '1';

				WHEN div1	=>		-- divu
					setstate <="01";
					next_micro_state <= div2;
				WHEN div2	=>		-- divu
					IF (OP2out(31 downto 16)=x"0000" OR opcode(15)='1' OR DIV_Mode=0) AND OP2out(15 downto 0)=x"0000" THEN		--div zero
						set_Z_error <= '1';
					ELSE
						next_micro_state <= div3;
					END IF;
					set(ld_rot_cnt) <= '1'; 
					setstate <="01";
				WHEN div3	=>		-- divu
					IF opcode(15)='1' OR DIV_Mode=0 THEN
						set_rot_cnt <= "001101";
					ELSE
						set_rot_cnt <= "011101";
					END IF;
					setstate <="01";
					next_micro_state <= div4;
				WHEN div4	=>		-- divu
					setstate <="01";
					IF rot_cnt="00001" THEN
						next_micro_state <= div_end1;
					ELSE	
						next_micro_state <= div4;
					END IF;
				WHEN div_end1	=>		-- divu
					IF z_error='0' AND set_V_Flag='0' THEN
						set(Regwrena) <= '1';
					END IF;
					IF opcode(15)='0' AND (DIV_Mode=1 OR DIV_Mode=2) THEN
						dest_2ndLbits <= '1';
						set(write_reminder) <= '1';
						next_micro_state <= div_end2;
						setstate <="01";
					END IF;
					set(opcDIVU) <= '1';
					datatype <= "10";
				WHEN div_end2	=>		-- divu
					IF exec(Regwrena)='1' THEN
						set(Regwrena) <= '1';
					ELSE	
						set(no_Flags) <= '1';
					END IF;
					dest_2ndHbits <= '1';
					set(opcDIVU) <= '1';
					
				WHEN rota1	=>
					IF OP2out(5 downto 0)/="000000" THEN
						set_rot_cnt <= OP2out(5 downto 0);
					ELSE
						set_exec(rot_nop) <= '1';
					END IF;
					
				WHEN bf1 =>
					setstate <="10";
	
				WHEN OTHERS => NULL;
			END CASE;


	END PROCESS;

-----------------------------------------------------------------------------
-- The word an exception frame state writes for the address and access
-- errors (what the trap states take otherwise is in the data_write_tmp
-- chain): format $7 (access error), the 68040 format $2, the 68000 group 0
-- frame and the 68010/68020 formats $8 and $A.
-----------------------------------------------------------------------------
  process (micro_state, cpu, cpu040, acc_frame, ae_frame, ae_xword, trap_vector, acc_pc, acc_srh, acc_ccr,
		   ae_addr, exe_pc, ae_pc, ae_sr, ae_ir, ae_status)
  begin
	fr_sel <= '1'; fr_lo <= '1'; fr_sf2 <= '0';
	fr_word <= (others => '0');
	if acc_frame = '1' and micro_state = ae_push then
	  fr_word(15 downto 0) <= ae_xword;
	elsif acc_frame = '1' and micro_state = trap0 then
	  fr_word(15 downto 0) <= "0111" & trap_vector(11 downto 0);		-- format $7
	elsif acc_frame = '1' and micro_state = trap1 then
	  fr_word <= acc_pc; fr_lo <= '0';
	elsif acc_frame = '1' and micro_state = trap2 then
	  fr_word(15 downto 0) <= acc_srh & acc_ccr;
	elsif ae_frame = '1' and cpu040 = '1' and micro_state = trap00 then
	  fr_word <= ae_addr(31 downto 1) & '0'; fr_lo <= '0'; fr_sf2 <= '1';	-- 68040: format $2, A0 cleared
	elsif ae_frame = '1' and cpu040 = '1' and micro_state = trap1 then
	  fr_word <= exe_pc; fr_lo <= '0';				-- the instruction that caused it
	elsif ae_frame = '1' and cpu = "00" and micro_state = trap0 then
	  fr_word <= ae_pc; fr_lo <= '0';
	elsif ae_frame = '1' and micro_state = ae_push then
	  fr_word(15 downto 0) <= ae_xword;
	elsif ae_frame = '1' and cpu = "01" and micro_state = trap0 then
	  fr_word(15 downto 0) <= "1000" & trap_vector(11 downto 0);		-- format $8
	elsif ae_frame = '1' and cpu = "11" and micro_state = trap0 then
	  fr_word(15 downto 0) <= "1010" & trap_vector(11 downto 0);		-- format $A
	elsif ae_frame = '1' and cpu040 = '0' and micro_state = trap1 then
	  fr_word <= ae_pc; fr_lo <= '0';
	elsif ae_frame = '1' and micro_state = trap2 then
	  fr_word(15 downto 0) <= ae_sr;				-- the SR at the fault (after an RTE, the new one)
	elsif ae_frame = '1' and micro_state = trap4 then
	  fr_word(15 downto 0) <= ae_ir;
	elsif ae_frame = '1' and micro_state = trap5 then
	  fr_word <= ae_addr; fr_lo <= '0';
	elsif ae_frame = '1' and micro_state = trap6 then
	  fr_word(15 downto 0) <= ae_status;
	else
	  fr_sel <= '0';
	end if;
  end process;

-----------------------------------------------------------------------------
-- 68040 access error (UM 8.2.1, 8.4.6). The stacked PC is the instruction
-- that faulted, which restarts on RTE, or for a fault on the fetch of the
-- next opcode the address of that opcode. SSW: MA, ATC, RW, SIZE (00 long,
-- 01 byte, 10 word), TT = 0, TM = the function code.
-----------------------------------------------------------------------------
  process (clk)
	variable sz : std_logic_vector(1 downto 0);
	variable rw : std_logic;
	variable v : std_logic_vector(31 downto 0);
	variable n2 : integer range 0 to 7;
  begin
	if rising_edge(clk) then
	  if Reset = '1' then
		acc_frame <= '0';
		acc_fpend <= '0';
		acc_wpend <= '0';
		acc_lw2 <= '0';
	  elsif clkena_core = '1' then
		-- the address of MOVEM's first transfer (its EA for the CM frame)
		if decodeOPC = '1' then
		  movem_first <= '1';
		elsif state(1) = '1' and movem_first = '1' then
		  movem_ea <= addr_l;
		  movem_first <= '0';
		end if;
		if state(1) = '1' and memmaskmux(3) = '0' and clkena_lw = '0' then
		  acc_lw2 <= '1';
		elsif clkena_lw = '1' then
		  acc_lw2 <= '0';
		end if;
		if acc_now = '1' then
		  rw := NOT mmu_wr;
		  if state = "00" or fpu_bus_act = '1' then
			sz := "10";
		  elsif memmask(3) = '1' then
			sz := "01";
		  elsif acc_lw2 = '1' or memmaskmux(3) = '0' then
			sz := "00";
		  else
			sz := "10";
		  end if;
		  acc_ssw <= "0000" & (acc_lw2 and not acc_tea) & not acc_tea & '0' & rw & '0' & sz & "00" & mmu_fc;
		  -- MOVEM: CM, and the address its transfers start at as the EA
		  acc_cm <= '0';
		  if opcode(15 downto 11) = "01001" and opcode(9 downto 7) = "001" then
			acc_ssw(12) <= '1';
			acc_cm <= '1';
			if movem_first = '1' then
			  acc_ea <= addr_l;
			else
			  acc_ea <= movem_ea;
			end if;
		  end if;
		  -- WB1: the write as it goes on the bus, memory aligned (table 8-5)
		  acc_wb1 <= '0';
		  acc_wb1s <= '1' & sz & "00" & mmu_fc;
		  case sz is
			when "01" => v := data_write_muxin(7 downto 0) & x"000000";
			when "10" => v := data_write_muxin(15 downto 0) & x"0000";
			when others => v := data_write_muxin;
		  end case;
		  if acc_lw2 = '1' then
			n2 := conv_integer(addr_l(1 downto 0)) + 2;
		  else
			n2 := conv_integer(addr_l(1 downto 0));
		  end if;
		  case n2 mod 4 is
			when 1 => acc_wb1d <= v(7 downto 0) & v(31 downto 8);
			when 2 => acc_wb1d <= v(15 downto 0) & v(31 downto 16);
			when 3 => acc_wb1d <= v(23 downto 0) & v(31 downto 24);
			when others => acc_wb1d <= v;
		  end case;
		  if acc_lw2 = '1' then
			acc_fa <= addr_l - 2;
			acc_wb2a <= addr_l - 2;
		  else
			acc_fa <= addr_l;
			acc_wb2a <= addr_l;
		  end if;
		  acc_wb <= '0';
		  acc_m16w <= '0';
		  acc_wb2s <= '1' & sz & "00" & mmu_fc;
		  acc_wb2d <= data_write_muxin;		-- register aligned (table 8-5)
		  if acc_wdefer = '1' then
			acc_wpend <= '1';
			if acc_tea = '1' then
			  acc_wb1 <= '1';
			else
			  acc_wb <= '1';
			end if;
		  end if;
		  if m16_active = '1' then
			-- MOVE16: the line (SIZE 11, TT 01); the instruction restarts. A
			-- write fault holds the line in WB2 and PD0-PD3 (table 8-6, write
			-- page fault with a MOVE16 in WB2); a write bus error in WB1
			acc_ssw <= "00000" & not acc_tea & '0' & rw & '0' & "11" & "01" & mmu_fc;
			acc_wb1s <= '1' & "11" & "01" & mmu_fc;
			acc_wb2s <= '1' & "11" & "01" & mmu_fc;
			acc_wb2d <= m16_buf(0) & m16_buf(1);
			if m16_step(3) = '1' then
			  acc_fa <= m16_dst;
			  acc_wb2a <= m16_dst;
			  acc_wb <= not acc_tea;
			  acc_wb1 <= acc_tea;
			  acc_m16w <= '1';
			else
			  acc_fa <= m16_src;
			end if;
		  end if;
		end if;
		if acc_now = '1' and state = "00" then
		  acc_fpend <= '1';				-- a fetch: decided in the next cycle
		elsif acc_restart = '1' and clkena_lw = '1' then
		  acc_fpend <= '0';
		  acc_wpend <= '0';
		  acc_frame <= '1';
		  acc_pc <= exe_pc;				-- the instruction restarts
		  acc_srh <= FlagsSR;
		elsif acc_go = '1' and clkena_lw = '1' then
		  acc_fpend <= '0';
		  acc_wpend <= '0';
		  acc_frame <= '1';
		  if acc_wpend = '1' then
			acc_pc <= TG68_PC - 2;		-- a held write: the instruction after it,
										-- the one being decoded
		  else
			acc_pc <= acc_fa;			-- the next instruction, at the faulting fetch
		  end if;
		  acc_srh <= FlagsSR;
		elsif acc_fpend = '1' and interrupt = '1' then
		  acc_fpend <= '0';				-- not used: an interrupt was taken instead
		elsif setopcode = '1' and clkena_lw = '1' then
		  acc_frame <= '0';
		end if;
		if micro_state = ae_fix1 and clkena_lw = '1' then
		  acc_ccr <= Flags;			-- after the last write-back of the instruction
		end if;
	  end if;
	end if;
  end process;

-----------------------------------------------------------------------------
-- The words of the 68010 format $8 frame (MC68000 UM figure 6-8) and the
-- 68020 format $A frame (MC68020 UM table 6-5) below the format word,
-- index 0 at SP+8. Internal and reserved words are zero.
-----------------------------------------------------------------------------
  process (cpu, ae_cnt, ae_ssw, ae_addr, ae_dob, acc_frame, acc_ssw, acc_fa, acc_wb, acc_wb2s, acc_wb2a, acc_wb2d,
		   acc_m16w, m16_buf, acc_wb1, acc_wb1s, acc_wb1d, acc_cm, acc_ea)
  begin
	ae_xword <= (others => '0');
	if acc_frame = '1' then
	  -- 68040 format $7 (UM 8.4.6): EA, SSW, WB3S-WB1S, FA, then write-back
	  -- and push data; only WB2 can be pending (a held write or a MOVE16
	  -- write), with the line in PD0-PD3 for a MOVE16
	  case ae_cnt is
		when 2 => ae_xword <= acc_ssw;						-- SP+$0C
		when 6 => ae_xword <= acc_fa(31 downto 16);		-- SP+$14
		when 7 => ae_xword <= acc_fa(15 downto 0);
		when others => null;
	  end case;
	  if acc_wb = '1' then
		case ae_cnt is
		  when 4 => ae_xword <= X"00" & acc_wb2s;			-- SP+$10, WB2S
		  when 12 => ae_xword <= acc_wb2a(31 downto 16);	-- SP+$20, WB2A
		  when 13 => ae_xword <= acc_wb2a(15 downto 0);
		  when 14 => ae_xword <= acc_wb2d(31 downto 16);	-- SP+$24, WB2D
		  when 15 => ae_xword <= acc_wb2d(15 downto 0);
		  when others => null;
		end case;
	  end if;
	  if acc_cm = '1' then
		case ae_cnt is
		  when 0 => ae_xword <= acc_ea(31 downto 16);		-- SP+$08, EA
		  when 1 => ae_xword <= acc_ea(15 downto 0);
		  when others => null;
		end case;
	  end if;
	  if acc_wb1 = '1' then
		case ae_cnt is
		  when 5 => ae_xword <= X"00" & acc_wb1s;			-- SP+$12, WB1S
		  when 16 => ae_xword <= acc_fa(31 downto 16);		-- SP+$28, WB1A = FA
		  when 17 => ae_xword <= acc_fa(15 downto 0);
		  when 18 => ae_xword <= acc_wb1d(31 downto 16);	-- SP+$2C, WB1D
		  when 19 => ae_xword <= acc_wb1d(15 downto 0);
		  when others => null;
		end case;
	  end if;
	  if acc_m16w = '1' and ae_cnt >= 18 then
		ae_xword <= m16_buf(ae_cnt - 18);					-- SP+$2C, PD0-PD3
	  end if;
	elsif cpu(1) = '1' then
	  if ae_cnt = 1 then ae_xword <= ae_ssw; end if;		-- SP+$0A
	else
	  case ae_cnt is
		when 0 => ae_xword <= ae_ssw;						-- SP+$08
		when 1 => ae_xword <= ae_addr(31 downto 16);		-- fault address
		when 2 => ae_xword <= ae_addr(15 downto 0);
		when 4 => ae_xword <= ae_dob;						-- SP+$10, data output buffer
		when others => null;
	  end case;
	end if;
  end process;

-----------------------------------------------------------------------------
-- Address error frame (68000). Status word: R/W (1 = read), I/N (1 for an
-- instruction fetch, as the SingleStepTests vectors have it) and the
-- function code, with bits 15-5 of the instruction register above them
-- (undefined in the MC68000 User's Manual figure 6-7, the IRD bits on the
-- chip). The stacked PC: the fault address - 4 for a fetch, TG68_PC - 4
-- for data; the 68000 stacks a PC "advanced 2-10 bytes beyond" the first
-- word of the instruction (UM 6.3.9.1).
-----------------------------------------------------------------------------
  process (clk)
  begin
	if rising_edge(clk) then
	  if Reset = '1' then
		ae_frame <= '0';
	  elsif clkena_core = '1' then
		if ae_now = '1' then
		  ae_frame <= '1';
		  ae_fix_r <= ae_fix;
		  ae_fix_idx_r <= ae_fix_idx;
		  ae_fix_val_r <= ae_fix_val;
		  ae_addr <= ae_faddr;
		  ae_ir <= opcode;
		  if state = "11" then
			-- the word as an aligned access would carry it (the write mux
			-- shifts an odd access by a byte)
			if memmask(2) = '0' then
			  ae_dob <= data_write_muxin(31 downto 16);
			else
			  ae_dob <= data_write_muxin(15 downto 0);
			end if;
		  else
			ae_dob <= (others => '0');
		  end if;
		  if cpu(1) = '1' then
			-- 68020: RC and RB, the pipeline refilled (MC68020 UM 6.2.1)
			ae_ssw <= X"3000";
		  elsif state = "00" then
			-- 68010: IF, read, the function code (MC68000 UM figure 6-9)
			ae_ssw <= "0010000100000" & FlagsSR(5) & "10";
		  else
			-- 68010 data: DF and RW for a read, neither for a write
			ae_ssw <= "000" & (NOT state(0)) & "000" & (NOT state(0)) & "00000" & FlagsSR(5) & "01";
		  end if;
		  if ae_ccr_force = '1' then
			ae_sr <= FlagsSR & "000" & ae_ccr;
		  else
			ae_sr <= FlagsSR & Flags;
		  end if;
		  if state = "00" then
			ae_status <= opcode(15 downto 5) & "11" & FlagsSR(5) & "10";	-- program
			ae_base <= addr;
			if cpu(1) = '1' then
			  ae_off <= X"00000000";	-- 68020: the next instruction (UM table 6-5)
			else
			  ae_off <= X"FFFFFFFC";	-- addr - 4
			end if;
		  else
			ae_status <= opcode(15 downto 5) & (NOT state(0)) & '0' & FlagsSR(5) & "01";	-- data
			if ae_move_w = '1' then
			  -- a MOVE has fetched its source extension words, and one more
			  -- word unless the destination is (An) or (An)+, when its write
			  -- faults (SingleStepTests 68000)
			  ae_base <= exe_pc;
			  if opcode(8 downto 6) = "010" or opcode(8 downto 6) = "011" then
				ae_off <= X"00000000" + ae_srcext;
			  elsif opcode(11 downto 6) = "001111" and
					(opcode(5 downto 4) = "00" or opcode(5 downto 0) = "111100") then
				-- to (xxx).L from a register or immediate data: one more word
				ae_off <= X"00000004" + ae_srcext;
			  else
				ae_off <= X"00000002" + ae_srcext;
			  end if;
			else
			  ae_base <= TG68_PC;
			  ae_off <= X"FFFFFFFC";		-- TG68_PC - 4
			end if;
		  end if;
		elsif setopcode = '1' and clkena_lw = '1' then
		  ae_frame <= '0';
		end if;
		if clkena_lw = '1' then
		  if micro_state = ae_fix1 then
			if acc_frame = '1' then ae_cnt <= 25;
			elsif cpu(1) = '1' then ae_cnt <= 11; else ae_cnt <= 24; end if;
		  elsif micro_state = ae_push and ae_cnt /= 0 then
			ae_cnt <= ae_cnt - 1;
		  end if;
		end if;
		-- the first data read of an instruction (ADDX/SUBX/CMPM: the source)
		if decodeOPC = '1' then
		  ae_read_done <= '0';
		elsif state = "10" and clkena_lw = '1' and ae_now = '0' then
		  ae_read_done <= '1';
		end if;
	  end if;
	end if;
  end process;

  -- the 68000 writes a long operand to -(An) low word first (MOVE, MOVEM),
  -- and ADDX.L/SUBX.L read theirs that way, so the fault address is An - 2
  -- where TG68K.C starts at An - 4
  ae_move_w <= '1' WHEN state="11" AND opcode(15 downto 14)="00" AND opcode(13 downto 12)/="00" ELSE '0';
  ae_faddr <= addr + 2 WHEN memmask(2)='0' AND
                            ((state="11" AND ae_move_w='1' AND opcode(8 downto 6)="100") OR
                             (state="11" AND opcode(15 downto 7)="010010001" AND opcode(5 downto 3)="100") OR
                             -- ADDX.L/SUBX.L -(Ay),-(Ax) read low word first too
                             (state="10" AND (opcode(15 downto 12)="1101" OR opcode(15 downto 12)="1001") AND
                              opcode(8 downto 3)="110001")) ELSE addr;
  process (opcode)
  begin
	ae_srcext <= 0;
	case opcode(5 downto 3) is
	  when "101" | "110" => ae_srcext <= 2;
	  when "111" =>
		case opcode(2 downto 0) is
		  when "000" | "010" | "011" => ae_srcext <= 2;
		  when "001" => ae_srcext <= 4;
		  when "100" =>
			if opcode(13 downto 12) = "10" then ae_srcext <= 4; else ae_srcext <= 2; end if;
		  when others => null;
		end case;
	  when others => null;
	end case;
  end process;

  ccr_force <= '1' WHEN ae_ccr_force='1' OR micro_state=rte_ferr ELSE '0';
  ccr_val <= rte_ccr(4 downto 0) WHEN micro_state=rte_ferr ELSE ae_ccr;
  ae_pc <= ae_base + ae_off;
  -- the format error frame: format $0, the PC of the RTE
  process (clk)
  begin
	if rising_edge(clk) then
	  if Reset = '1' then
		fmt_err <= '0';
	  elsif clkena_lw = '1' then
		if micro_state = rte_ferr then
		  fmt_err <= '1';
		elsif micro_state = trap3 then
		  fmt_err <= '0';
		end if;
	  end if;
	end if;
  end process;

  -- MOVE whose write faults: the 68000 has already set N and Z from the data
  -- (V and C clear, X kept), as the SingleStepTests vectors show
  process (ae_now, state, opcode, data_write_muxin, Flags)
	variable n, z : std_logic;
  begin
	ae_ccr_force <= '0';
	ae_ccr <= Flags(4 downto 0);
	if ae_now = '1' and state = "11" and opcode(15 downto 14) = "00" and opcode(13 downto 12) /= "00" and
	   opcode(8 downto 6) /= "001" then
	  if opcode(13 downto 12) = "10" then
		n := data_write_muxin(31);
		if data_write_muxin = X"00000000" then z := '1'; else z := '0'; end if;
	  else
		n := data_write_muxin(15);
		if data_write_muxin(15 downto 0) = X"0000" then z := '1'; else z := '0'; end if;
	  end if;
	  ae_ccr_force <= '1';
	  ae_ccr <= Flags(4) & n & z & "00";
	end if;
  end process;

  -- the address register of the faulting access, left as the 68000 leaves
  -- it (SingleStepTests 68000): -(An) decremented to the fault address,
  -- (An)+ past the operand on a read and not moved on a write (MOVEM: +2)
  process (ae_now, state, opcode, addr, memmask, ae_read_done, regfile, ae_faddr)
	variable mode, reg : std_logic_vector(2 downto 0);
	variable sz : integer range 2 to 4;
  begin
	if memmask(2) = '1' then sz := 2; else sz := 4; end if;
	if opcode(15 downto 14) = "00" and opcode(13 downto 12) /= "00" and state = "11" then
	  mode := opcode(8 downto 6); reg := opcode(11 downto 9);		-- MOVE destination
	elsif ((opcode(15 downto 12) = "1001" or opcode(15 downto 12) = "1101") and opcode(8) = '1' and
		   opcode(5 downto 4) = "00" and opcode(7 downto 6) /= "11") or
		  (opcode(15 downto 12) = "1011" and opcode(8) = '1' and opcode(5 downto 3) = "001" and
		   opcode(7 downto 6) /= "11") then
	  -- ADDX/SUBX -(Ay),-(Ax) and CMPM (Ay)+,(Ax)+: Ay first, then Ax
	  if opcode(3) = '1' and opcode(15 downto 12) /= "1011" then mode := "100"; else mode := "011"; end if;
	  if opcode(15 downto 12) = "1011" then mode := "011"; end if;
	  if opcode(3) = '0' and opcode(15 downto 12) /= "1011" then mode := "000"; end if;
	  if ae_read_done = '1' then reg := opcode(11 downto 9); else reg := opcode(2 downto 0); end if;
	else
	  mode := opcode(5 downto 3); reg := opcode(2 downto 0);
	end if;
	ae_fix <= '0';
	ae_fix_idx <= 8 + conv_integer(reg);
	ae_fix_val <= ae_faddr;
	if ae_now = '1' and cpu = "00" and state = "00" and opcode(15 downto 6) = "0100111010" then
	  -- JSR to an odd address: the 68000 faults before pushing the return
	  -- address, which TG68K.C has pushed already
	  ae_fix <= '1';
	  ae_fix_idx <= 15;
	  ae_fix_val <= regfile(15) + 4;
	elsif ae_now = '1' and state /= "00" and opcode(15 downto 11) = "01001" and opcode(9 downto 7) = "001" and
		  mode = "100" then
	  -- MOVEM -(An): An is only written at the end
	  ae_fix <= '1';
	  ae_fix_val <= ae_faddr + 2;
	elsif ae_now = '1' and state /= "00" then
	  if mode = "100" then
		ae_fix <= '1';
	  elsif mode = "011" then
		ae_fix <= '1';
		if state = "10" then
		  if opcode(15 downto 7) = "010011001" then
			ae_fix_val <= ae_faddr + 2;					-- MOVEM (An)+
		  else
			ae_fix_val <= ae_faddr + sz;
		  end if;
		end if;
	  end if;
	end if;
  end process;

-----------------------------------------------------------------------------
-- 68040 FPU
-----------------------------------------------------------------------------
  fpu_fbcc <= '1' WHEN cpu040='1' AND opcode(15 downto 7)="111100101" ELSE '0';
  -- cpGEN and FScc/FDBcc/FTRAPcc have a command or condition word after the opcode
  fpu_gen <= '1' WHEN cpu040='1' AND opcode(15 downto 7)="111100100" AND
                      NOT (opcode(6)='1' AND opcode(5 downto 3)="111" AND opcode(2 downto 0)>"100") ELSE '0';
  fpu_ftrapcc <= '1' WHEN opcode(8 downto 6)="001" AND opcode(5 downto 3)="111" AND
                          opcode(2 downto 1)/="00" ELSE '0';
  fpu_ins <= '1' WHEN fpu_gen='1' OR (cpu040='1' AND opcode(15 downto 7)="111100110" AND opcode(6)='0') OR
                      (cpu040='1' AND opcode(15 downto 6)="1111001101") ELSE '0';
  -- (d16,An), (d8,An,Xn), absolute and PC-relative modes
  fpu_memea <= '1' WHEN (opcode(5 downto 3)="101" OR opcode(5 downto 3)="110" OR
                         (opcode(5 downto 3)="111" AND opcode(2)='0')) AND fpu_ftrapcc='0' ELSE '0';
  fpu_pred <= exe_opcode(5 downto 0);
  fpu_badcmd <= '1' WHEN (opcode(6)='0' AND fpu_unimpl='1') OR (opcode(6)='1' AND sndOPC(15 downto 5)/="00000000000") ELSE '0';
  fpu_start <= '1' WHEN micro_state=fpu_go AND NOT (fpu_gen='1' AND fpu_badcmd='1') ELSE '0';
  -- that Line-F stacks the address of the instruction (the effective address
  -- may have been fetched by then)
  process (clk)
  begin
	if rising_edge(clk) then
	  if Reset = '1' then
		fpu_lf <= '0';
	  elsif clkena_lw = '1' then
		if micro_state = fpu_go and fpu_gen = '1' and fpu_badcmd = '1' then
		  fpu_lf <= '1';
		elsif micro_state = trap3 then
		  fpu_lf <= '0';
		end if;
	  end if;
	end if;
  end process;
  fpu_jump <= '1' WHEN micro_state=fpu_end ELSE '0';
  -- FBcc tests its predicate in bra1: a signaling one on a NaN sets BSUN
  fpu_bsun <= '1' WHEN micro_state=bra1 AND cpu040='1' AND exe_opcode(15 downto 7)="111100101" ELSE '0';
  fpu_trap2 <= '1' WHEN micro_state=fpu_wait AND fpu_done='1' AND fpu_unimp='1' ELSE '0';
  fpu_trap55 <= '1' WHEN micro_state=fpu_wait AND fpu_done='1' AND fpu_unsupp='1' ELSE '0';
  fpu_trapx <= '1' WHEN micro_state=fpu_wait AND fpu_done='1' AND fpu_xexc='1' ELSE '0';
  fpu_fbx <= '1' WHEN micro_state=idle AND (fpu_xpend='1' OR (opcode(4)='1' AND fpu_nan='1' AND fpu_bsun_en='1')) ELSE '0';
  fpu_set_bsun <= '1' WHEN fpu_fbcc='1' AND fpu_fbx='1' AND fpu_xpend='0' ELSE '0';
  fpx_v <= fpu_xvec WHEN micro_state=fpu_wait ELSE fpu_xpvec WHEN fpu_xpend='1' ELSE "000";
  -- marks the exception entry of an unimplemented FP instruction
  process (clk)
  begin
	if rising_edge(clk) then
	  if Reset = '1' then
		fpu_tf <= '0';
		fpu_tfp <= '0';
		fpu_tu <= '0';
		fpu_tx <= '0';
	  elsif clkena_lw = '1' then
		if fpu_trap2 = '1' then
		  fpu_tf <= '1';
		elsif micro_state = trap3 then
		  fpu_tf <= '0';
		end if;
		if fpu_trap55 = '1' or (fpu_trapx = '1' and fpu_xpost = '1') then
		  fpu_tu <= '1';
		elsif micro_state = trap3 then
		  fpu_tu <= '0';
		end if;
		if trap_fpx = '1' and fpu_tu = '0' and not (fpu_trapx = '1' and fpu_xpost = '1' and fpu_xhere = '0') then
		  fpu_tx <= '1';
		elsif micro_state = trap3 then
		  fpu_tx <= '0';
		end if;
		if micro_state = fpu_wait and fpu_done = '1' and fpu_ftrap = '1' then
		  fpu_tfp <= '1';
		elsif micro_state = trap3 then
		  fpu_tfp <= '0';
		end if;
	  end if;
	end if;
  end process;
  fpu_rd_data <= regfile(fpu_rd_idx);

  -- the command word of a cpGEN instruction is on data_read during its
  -- decode, and is in sndOPC from the next cycle, fpu_go, where FMOVECR and
  -- effective addresses the instruction does not allow take Line-F (from the
  -- register: the data bus in the decode logic made a path from the memory
  -- to every register of the core in MinimigAGA)
  process (sndOPC, opcode)
	variable c : std_logic_vector(15 downto 0);
	variable m : std_logic_vector(2 downto 0);
	variable r : std_logic_vector(2 downto 0);
	variable src, single : boolean;
  begin
	c := sndOPC;
	m := opcode(5 downto 3);
	r := opcode(2 downto 0);
	fpu_unimpl <= '0';
	-- effective address modes the instruction does not allow (PRM section 5)
	src := c(15 downto 13) = "010" or c(15 downto 13) = "100" or c(15 downto 13) = "110";
	single := c(12 downto 10) = "100" or c(12 downto 10) = "010" or c(12 downto 10) = "001";
	if c(15 downto 13) /= "000" then
	  if m = "001" and not ((c(15 downto 13) = "100" or c(15 downto 13) = "101") and c(12 downto 10) = "001") then
		fpu_unimpl <= '1';					-- An: only a single FPIAR
	  elsif m = "000" and (c(15 downto 13) = "110" or c(15 downto 13) = "111" or
						   ((c(15 downto 13) = "100" or c(15 downto 13) = "101") and not single) or
						   ((c(15 downto 13) = "010" or c(15 downto 13) = "011") and
							(c(12 downto 10) = "010" or c(12 downto 10) = "011" or c(12 downto 10) = "101" or
							 c(12 downto 10) = "111"))) then
		fpu_unimpl <= '1';					-- Dn: B W L S, or one control register
	  elsif m = "111" and (r(2 downto 1) = "11" or r = "101") then
		fpu_unimpl <= '1';
	  elsif m = "111" and (r = "100" or r = "010" or r = "011") and not src then
		fpu_unimpl <= '1';					-- #imm and PC-relative: sources only
	  elsif c(15 downto 13) = "111" and m = "011" then
		fpu_unimpl <= '1';					-- FMOVEM to memory: no (An)+
	  elsif c(15 downto 13) = "110" and m = "100" then
		fpu_unimpl <= '1';					-- FMOVEM from memory: no -(An)
	  end if;
	end if;
	case c(15 downto 13) is
	  when "000" | "010" =>
		-- operations the 68040 leaves to the FPSP run as far as the operand
		-- fetch and take vector 11 with a format $2 frame (TG68K_FPU)
		-- FMOVECR; packed decimal goes to the FPU (vector 55)
		if c(14) = '1' and c(12 downto 10) = "111" then
		  fpu_unimpl <= '1';
		end if;
	  when "011" => null;		-- FMOVE.P out included (vector 55)
	  when "110" | "111" => null;		-- static or dynamic register lists
	  when "100" | "101" => null;
	  when others => fpu_unimpl <= '1';
	end case;
  end process;

  -- effective address: built by the kernel (captured when PEA would write
  -- it) or, for #imm, after the command word
  process (clk)
  begin
	if rising_edge(clk) then
	  if clkena_lw = '1' and exec(get_ea_now) = '1' and fpu_ins = '1' then
		fpu_ea_r <= addr;
	  end if;
	end if;
  end process;
  -- the PC-relative modes take the PC of the extension word as base, but
  -- the kernel builds them from the PC of the command word in front of it
  fpu_ea <= exe_pc + 4 WHEN opcode(8 downto 6)="001" AND opcode(5 downto 3)="001" ELSE	-- FDBcc displacement
            exe_pc + 5 WHEN opcode(5 downto 0)="111100" AND sndOPC(12 downto 10)="110" ELSE
            exe_pc + 4 WHEN opcode(5 downto 0)="111100" ELSE
            fpu_ea_r + 2 WHEN fpu_gen='1' AND opcode(5 downto 1)="11101" ELSE fpu_ea_r;

  -- bytes after the opcode (and command word): extension words of the
  -- effective address, or the immediate data
  process (opcode, sndOPC, brief, fpu_ftrapcc)
	variable n : integer range 0 to 16;
	variable full : integer range 0 to 16;
  begin
	-- (d8,An,Xn) and (d8,PC,Xn): the brief or full extension word, with
	-- the base and outer displacements of the full format
	full := 2;
	if brief(8) = '1' then
	  if brief(5 downto 4) = "10" then full := full + 2; elsif brief(5 downto 4) = "11" then full := full + 4; end if;
	  if brief(1 downto 0) = "10" then full := full + 2; elsif brief(1 downto 0) = "11" then full := full + 4; end if;
	end if;
	n := 0;
	if fpu_ftrapcc = '1' then
	  -- FTRAPcc.W, .L or no operand
	  case opcode(2 downto 0) is
		when "010" => n := 2;
		when "011" => n := 4;
		when others => n := 0;
	  end case;
	else
	  case opcode(5 downto 3) is
		when "001" =>
		  if opcode(8 downto 6) = "001" then n := 2; end if;		-- FDBcc displacement
		when "101" => n := 2;
		when "110" => n := full;
		when "111" =>
		  case opcode(2 downto 0) is
			when "000" | "010" => n := 2;
			when "001" => n := 4;
			when "011" => n := full;
			when "100" =>
			  if sndOPC(15 downto 13) = "100" then
				if sndOPC(12) = '1' then n := n + 4; end if;
				if sndOPC(11) = '1' then n := n + 4; end if;
				if sndOPC(10) = '1' then n := n + 4; end if;
			  else
				case sndOPC(12 downto 10) is
				  when "000" | "001" => n := 4;
				  when "010" | "011" => n := 12;
				  when "101" => n := 8;
				  when others => n := 2;
				end case;
			  end if;
			when others => n := 0;
		  end case;
		when others => n := 0;
	  end case;
	end if;
	fpu_ext <= n;
  end process;
  fpu_next_pc <= exe_pc + 2 WHEN opcode(15 downto 8)=X"F5" ELSE			-- PTEST
                 exe_pc + 4 + fpu_ext WHEN fpu_gen='1' ELSE exe_pc + 2 + fpu_ext;
  fpu_target <= fpu_br_target WHEN fpu_br='1' ELSE fpu_next_pc;

  fpu : entity work.TG68K_FPU
	generic map (FPSP => FPU_FPSP)
	port map (clk => clk, reset => Reset, clkena => clkena_lw, start => fpu_start,
			  opcode => opcode, cmd => sndOPC, ea => fpu_ea, iaddr => exe_pc, done => fpu_done, abort => acc_restart,
			  unimp => fpu_unimp, unsupp => fpu_unsupp, upost => fpu_upost, ea_out => fpu_ea_out, ftrap => fpu_ftrap, br_take => fpu_br,
			  br_target => fpu_br_target,
			  rd_idx => fpu_rd_idx, rd_data => fpu_rd_data, wr_en => fpu_wr_en, wr_idx => fpu_wr_idx,
			  wr_data => fpu_wr_data, wr_size => fpu_wr_size, bus_act => fpu_bus_act,
			  bus_addr => fpu_bus_addr, bus_wr => fpu_bus_wr, bus_uds_n => fpu_uds_n,
			  bus_lds_n => fpu_lds_n, bus_wdata => fpu_bus_wdata, data_in => data_in,
			  pred => fpu_pred, pred_true => fpu_pred_true, pred_bsun => fpu_bsun,
			  xexc => fpu_xexc, xvec => fpu_xvec, xpost => fpu_xpost, xhere_o => fpu_xhere, xpend_o => fpu_xpend, xpend_vec => fpu_xpvec,
			  fpcc_nan => fpu_nan, fp_bsun_en => fpu_bsun_en, set_bsun => fpu_set_bsun);

-----------------------------------------------------------------------------
-- MOVE16 (68040)
--   1111 0110 0010 0xxx, 1xxx 0000 0000 0000   (Ax)+,(Ay)+
--   1111 0110 000o oyyy, address.L              00 (Ay)+,(xxx).L
--                                               01 (xxx).L,(Ay)+
--                                               10 (Ay),(xxx).L
--                                               11 (xxx).L,(Ay)
-- The line holding each address (low four bits ignored) is read with eight
-- word reads and written with eight word writes; the post-incremented
-- registers go up by 16 (once if Ax = Ay), as in Emu68.
-----------------------------------------------------------------------------
  m16_rx <= 8 + conv_integer(opcode(2 downto 0));
  m16_ry <= 8 + conv_integer(sndOPC(14 downto 12)) WHEN opcode(5)='1' ELSE 8 + conv_integer(opcode(2 downto 0));
  m16_inc_x <= opcode(5);
  m16_inc_y <= '1' WHEN opcode(5)='1' OR opcode(4)='0' ELSE '0';
  m16_last <= '1' WHEN m16_active='1' AND m16_step="1111" AND clkena_lw='1' ELSE '0';
  m16_addr <= m16_src(31 downto 4) & m16_step(2 downto 0) & '0' WHEN m16_step(3)='0' ELSE
              m16_dst(31 downto 4) & m16_step(2 downto 0) & '0';

  process (clk)
	variable absaddr, reg : std_logic_vector(31 downto 0);
  begin
	if rising_edge(clk) then
	  if Reset = '1' then
		m16_active <= '0';
		m16_done <= '0';
		m16_step <= "0000";
	  elsif clkena_lw = '1' then
		if micro_state = m16_abs then
		  m16_lo <= data_read(15 downto 0);
		end if;
		if acc_restart = '1' then
		  m16_active <= '0';			-- an access error: the MOVE16 restarts
		  m16_done <= '0';
		elsif micro_state = m16_go then
		  absaddr := sndOPC & m16_lo;
		  if opcode(5) = '1' then
			m16_src <= regfile(m16_rx);
			m16_dst <= regfile(m16_ry);
		  else
			reg := regfile(m16_ry);
			if opcode(3) = '1' then
			  m16_src <= absaddr;
			  m16_dst <= reg;
			else
			  m16_src <= reg;
			  m16_dst <= absaddr;
			end if;
		  end if;
		  m16_active <= '1';
		  m16_step <= "0000";
		elsif m16_active = '1' then
		  if m16_step(3) = '0' then
			m16_buf(conv_integer(m16_step(2 downto 0))) <= data_in;
		  end if;
		  if m16_step = "1111" then
			m16_active <= '0';
			m16_done <= '1';
		  else
			m16_step <= m16_step + 1;
		  end if;
		elsif micro_state /= m16_wait then
		  m16_done <= '0';
		end if;
	  end if;
	end if;
  end process;

-----------------------------------------------------------------------------
-- MOVEC
-----------------------------------------------------------------------------
  process (clk, SFC, DFC, VBR, CACR, CACR_DC, brief, cpu040, CACR040, TC040, TC040E, ITT0, ITT1, DTT0, DTT1, MMUSR, URP, SRP,
		   preMmode, regfile, OSP)
  begin
	-- all other hexa codes should give illegal isntruction exception
	if rising_edge(clk) then
	  if Reset = '1' then
		VBR <= (others => '0');
		CACR <= (others => '0');
		CACR_DC <= '1';
		CACR_DC_owned <= '0';
		-- reset clears the CACR and the E bits of TC and the TTRs and leaves
		-- the rest of the MMU registers alone (68040 UM 3.1.2, 8.2.10)
		CACR040 <= "00";
		ITT0(15) <= '0';
		ITT1(15) <= '0';
		TC040E <= '0';
		DTT0(15) <= '0';
		DTT1(15) <= '0';
	  elsif clkena_lw = '1' and mmu_ptest_done = '1' then
		MMUSR <= mmu_mmusr;
	  elsif clkena_lw = '1' and exec(movec_wr) = '1' then
		case brief(11 downto 0) is
		  when X"000" => SFC <= reg_QA(2 downto 0); -- SFC -- 68010+
		  when X"001" => DFC <= reg_QA(2 downto 0); -- DFC -- 68010+
		  when X"002" =>
			if cpu040 = '1' then
			  CACR040 <= reg_QA(31) & reg_QA(15);   -- DE, IE
			else
			  CACR <= reg_QA(3 downto 0); -- 68020+
			  CACR_DC <= reg_QA(8);
			  CACR_DC_owned <= '1';
			end if;
		  -- 68040 MMU registers (68040 UM 3.1): unimplemented bits read as 0
		  when X"003" => TC040 <= reg_QA(14); TC040E <= reg_QA(15);
		  when X"004" => ITT0 <= reg_QA and X"FFFFE364";
		  when X"005" => ITT1 <= reg_QA and X"FFFFE364";
		  when X"006" => DTT0 <= reg_QA and X"FFFFE364";
		  when X"007" => DTT1 <= reg_QA and X"FFFFE364";
		  when X"805" => MMUSR <= reg_QA;
		  when X"806" => URP <= reg_QA and X"FFFFFE00";
		  when X"807" => SRP <= reg_QA and X"FFFFFE00";
		  when X"800" => NULL; -- USP -- 68010+
		  when X"801" => VBR <= reg_QA; -- 68010+
		  when X"802" => NULL; -- CAAR -- 68020+
		  when X"803" => NULL; -- MSP -- 68020+ (in the register file process)
		  when X"804" => NULL; -- ISP -- 68020+
		  when others => NULL;
		end case;
	  end if;
	end if;

	movec_data <= (others => '0');
	case brief(11 downto 0) is
		when X"000" => movec_data <= "00000000000000000000000000000" & SFC;
		when X"001" => movec_data <= "00000000000000000000000000000" & DFC;
	  when X"002" =>
		if cpu040 = '1' then
		  movec_data <= CACR040(1) & "000000000000000" & CACR040(0) & "000000000000000";
		else
		  movec_data <= "0000000000000000000000000000" & (CACR AND "0011");
		  if D_Cache_Bit = 1 then
			movec_data(8) <= CACR_DC;
		  end if;
		end if;
	  when X"003" => movec_data <= X"0000" & TC040E & TC040 & "00000000000000";
	  when X"004" => movec_data <= ITT0;
	  when X"005" => movec_data <= ITT1;
	  when X"006" => movec_data <= DTT0;
	  when X"007" => movec_data <= DTT1;
	  when X"805" => movec_data <= MMUSR;
	  when X"806" => movec_data <= URP;
	  when X"807" => movec_data <= SRP;

	  when X"803" | X"804" =>		-- MSP, ISP: A7 when M selects it, else OSP
		if brief(0) = preMmode then
		  movec_data <= regfile(15);
		else
		  movec_data <= OSP;
		end if;
	  when X"801" => 
		movec_data <= VBR;
		--end if;
	  when others => NULL;
	end case;
  end process;

  -- control registers MOVEC accepts: the 68010 set, the 68020 additions
  -- (CAAR, MSP, ISP) and the 68040 set, which drops CAAR (68040 UM appendix D)
  process (brief, cpu, cpu040)
	variable c : std_logic_vector(11 downto 0);
  begin
	c := brief(11 downto 0);
	movec_ok <= '0';
	if c = X"000" or c = X"001" or c = X"800" or c = X"801" then
	  movec_ok <= '1';
	elsif cpu(1) = '1' and (c = X"002" or c = X"803" or c = X"804") then
	  movec_ok <= '1';
	elsif cpu040 = '0' and cpu(1) = '1' and c = X"802" then
	  movec_ok <= '1';
	elsif cpu040 = '1' and (c = X"003" or c = X"004" or c = X"005" or c = X"006" or c = X"007" or
						   c = X"805" or c = X"806" or c = X"807") then
	  movec_ok <= '1';
	end if;
  end process;

  -- CACR_out drives the caches outside the core (MinimigAGA: bit 0 enables
  -- them, a rising edge on bit 3 clears them, as in the 68020 CACR). In the
  -- 68040 mode bit 0 is DE or IE, and CINV or CPUSH of any cache raises bit 3
  -- for 256 clocks, then holds it low for 16 before a CINV or CPUSH that came
  -- meanwhile raises it again: MinimigAGA's cache (cpu_cache_new) samples the
  -- bit only while the CPU does not access it, so a pulse of one instruction
  -- was missed and the cache never cleared (AmigaOS's CacheClearU after
  -- LoadSeg, ramlib).
  CACR_out <= cinv040 & "00" & (CACR040(1) OR CACR040(0)) WHEN cpu040='1' ELSE CACR;
  data_write_lo <= data_write_mux(15 downto 0);		-- the low word of a long in one cycle
  VBR_out <= VBR;
  MMU_on_out <= TC040E AND cpu040;
  -- the data cache stays on until software writes the CACR (MiSTer Minimig)
  D_CACHE_out <= CACR040(1) WHEN cpu040='1' ELSE
                 CACR_DC OR NOT CACR_DC_owned WHEN D_Cache_Bit = 1 ELSE '1';
  process (clk)
  begin
	if rising_edge(clk) then
	  if Reset = '1' then
		cinv040 <= '0';
		cinv_pend <= '0';
		cinv_cnt <= 0;
	  else
		if cinv040 = '1' then
		  if cinv_cnt = 0 then
			cinv040 <= '0';
			cinv_cnt <= 15;				-- low for 16 clocks
		  else
			cinv_cnt <= cinv_cnt - 1;
		  end if;
		elsif cinv_cnt /= 0 then
		  cinv_cnt <= cinv_cnt - 1;
		elsif cinv_pend = '1' then
		  cinv040 <= '1';
		  cinv_cnt <= 255;				-- high for 256 clocks
		  cinv_pend <= '0';
		end if;
		if clkena_lw = '1' and decodeOPC = '1' and cpu040 = '1' and SVmode = '1' and opcode(15 downto 8) = X"F4" and
		   opcode(4 downto 3) /= "00" and opcode(7 downto 6) /= "00" then
		  cinv_pend <= '1';
		end if;
	  end if;
	end if;
  end process;
-----------------------------------------------------------------------------
-- Conditions
-----------------------------------------------------------------------------
PROCESS (exe_opcode, Flags, fpu_pred_true, cpu040)
	BEGIN
		CASE exe_opcode(11 downto 8) IS
			WHEN X"0" => exe_condition <= '1';
			WHEN X"1" => exe_condition <= '0';
			WHEN X"2" => exe_condition <=  NOT Flags(0) AND NOT Flags(2);
			WHEN X"3" => exe_condition <= Flags(0) OR Flags(2);
			WHEN X"4" => exe_condition <= NOT Flags(0);
			WHEN X"5" => exe_condition <= Flags(0);
			WHEN X"6" => exe_condition <= NOT Flags(2);
			WHEN X"7" => exe_condition <= Flags(2);
			WHEN X"8" => exe_condition <= NOT Flags(1);
			WHEN X"9" => exe_condition <= Flags(1);
			WHEN X"a" => exe_condition <= NOT Flags(3);
			WHEN X"b" => exe_condition <= Flags(3);
			WHEN X"c" => exe_condition <= (Flags(3) AND Flags(1)) OR (NOT Flags(3) AND NOT Flags(1));
			WHEN X"d" => exe_condition <= (Flags(3) AND NOT Flags(1)) OR (NOT Flags(3) AND Flags(1));
			WHEN X"e" => exe_condition <= (Flags(3) AND Flags(1) AND NOT Flags(2)) OR (NOT Flags(3) AND NOT Flags(1) AND NOT Flags(2));
			WHEN X"f" => exe_condition <= (Flags(3) AND NOT Flags(1)) OR (NOT Flags(3) AND Flags(1)) OR Flags(2);
			WHEN OTHERS => NULL;
		END CASE;
		IF cpu040='1' AND exe_opcode(15 downto 7)="111100101" THEN
			exe_condition <= fpu_pred_true;
		END IF;
	END PROCESS;
	
-----------------------------------------------------------------------------
-- Movem
-----------------------------------------------------------------------------
PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF clkena_lw='1' THEN
				movem_actiond <= exec(movem_action); 
				IF decodeOPC='1' THEN
					sndOPC <= data_read(15 downto 0);
				ELSIF exec(movem_action)='1' OR set(movem_action) ='1' THEN
					CASE movem_regaddr IS
						WHEN "0000" => sndOPC(0)  <= '0';
						WHEN "0001" => sndOPC(1)  <= '0';
						WHEN "0010" => sndOPC(2)  <= '0';
						WHEN "0011" => sndOPC(3)  <= '0';
						WHEN "0100" => sndOPC(4)  <= '0';
						WHEN "0101" => sndOPC(5)  <= '0';
						WHEN "0110" => sndOPC(6)  <= '0';
						WHEN "0111" => sndOPC(7)  <= '0';
						WHEN "1000" => sndOPC(8)  <= '0';
						WHEN "1001" => sndOPC(9)  <= '0';
						WHEN "1010" => sndOPC(10) <= '0';
						WHEN "1011" => sndOPC(11) <= '0';
						WHEN "1100" => sndOPC(12) <= '0';
						WHEN "1101" => sndOPC(13) <= '0';
						WHEN "1110" => sndOPC(14) <= '0';
						WHEN "1111" => sndOPC(15) <= '0';
						WHEN OTHERS => NULL;
					END CASE;
				END IF;
			END IF;
		END IF;
	END PROCESS;
	
PROCESS (sndOPC, movem_mux)
	BEGIN
		movem_regaddr <="0000";
		movem_run <= '1';
		IF sndOPC(3 downto 0)="0000" THEN
			IF sndOPC(7 downto 4)="0000" THEN
				movem_regaddr(3) <= '1';
				IF sndOPC(11 downto 8)="0000" THEN
					IF sndOPC(15 downto 12)="0000" THEN
						movem_run <= '0';
					END IF;
					movem_regaddr(2) <= '1';
					movem_mux <= sndOPC(15 downto 12);
				ELSE
					movem_mux <= sndOPC(11 downto 8);
				END IF;
			ELSE
				movem_mux <= sndOPC(7 downto 4);
				movem_regaddr(2) <= '1';
			END IF;
		ELSE
			movem_mux <= sndOPC(3 downto 0);
		END IF;
		IF movem_mux(1 downto 0)="00" THEN
			movem_regaddr(1) <= '1';
			IF movem_mux(2)='0' THEN
				movem_regaddr(0) <= '1';
			END IF;	
		ELSE		
			IF movem_mux(0)='0' THEN
				movem_regaddr(0) <= '1';
			END IF;	
		END  IF;
	END PROCESS;
END; 
