------------------------------------------------------------------------------
-- TG68K.C 68040 MMU
--
-- Address translation for the 68040 mode (M68040 User's Manual, section 3):
-- the transparent translation registers ITT0/ITT1 (instruction fetches) and
-- DTT0/DTT1 (data), and with TC E set the three-level tables from URP or
-- SRP, 4 or 8 Kbyte pages, indirect page descriptors, write and supervisor
-- protection and the U and M bits (table 3-1, by a read and a write, as the
-- core has no LOCK). An 8-entry address translation cache serves both
-- instruction and data accesses.
--
-- The kernel's bus request (act, laddr, wr, fc) goes through here: on a
-- hit, a transparent match or with E clear, paddr is the physical address
-- at once; otherwise stall holds the core while the table search runs on
-- the bus (bus_*), and the access goes on once the entry is in the cache.
-- A fault (invalid descriptor, write or supervisor violation) sets fault
-- and lets the access through untranslated without a bus cycle (quiet);
-- the kernel takes it as a bus error at the end of the instruction, since
-- TG68K.C cannot restart an instruction (no format $7 frame).
--
-- PTEST searches the tables for ptest_addr with the function code in
-- ptest_fc, loads the cache and returns the MMU status register value;
-- PFLUSH variants flush the cache (pflush_all: all entries, else the
-- non-global ones).
--
-- Copyright (c) 2026 Ramon Martinez. LGPL-3.0-or-later, as TG68K.C.
------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity TG68K_MMU is
	port (
		clk        : in  std_logic;
		reset      : in  std_logic;
		clkena     : in  std_logic;
		-- registers
		tc_e, tc_p : in  std_logic;
		urp, srp   : in  std_logic_vector(31 downto 0);
		itt0, itt1, dtt0, dtt1 : in std_logic_vector(31 downto 0);
		-- the core's access
		act        : in  std_logic;
		laddr      : in  std_logic_vector(31 downto 0);
		wr         : in  std_logic;
		fc         : in  std_logic_vector(2 downto 0);
		paddr      : out std_logic_vector(31 downto 0);
		stall      : out std_logic;
		quiet      : out std_logic;		-- no bus cycle for this access (faulted)
		fault      : out std_logic;		-- pulse
		-- table search bus cycles
		bus_act    : out std_logic;
		bus_addr   : out std_logic_vector(31 downto 0);
		bus_wr     : out std_logic;
		bus_wdata  : out std_logic_vector(15 downto 0);
		data_in    : in  std_logic_vector(15 downto 0);
		-- PTEST and PFLUSH
		ptest      : in  std_logic;
		ptest_addr : in  std_logic_vector(31 downto 0);
		ptest_fc   : in  std_logic_vector(2 downto 0);
		ptest_wr   : in  std_logic;
		ptest_done : out std_logic;
		mmusr      : out std_logic_vector(31 downto 0);
		pflush     : in  std_logic;
		pflush_all : in  std_logic
	);
end entity;

architecture rtl of TG68K_MMU is
	constant N : integer := 8;
	type page_t is array (0 to N - 1) of unsigned(19 downto 0);
	signal e_valid, e_super, e_w, e_m, e_s, e_g, e_inv : std_logic_vector(N - 1 downto 0) := (others => '0');
	signal e_lp, e_pp : page_t;
	signal victim : integer range 0 to N - 1 := 0;

	type wstate_t is (W_IDLE, W_RD_H, W_RD_L, W_CHECK, W_UPD, W_FILL, W_DONE);
	signal ws : wstate_t := W_IDLE;
	signal lvl : integer range 0 to 3;			-- 0 root, 1 pointer, 2 page, 3 indirect page
	signal w_addr : unsigned(31 downto 0);		-- descriptor address
	signal next_addr : unsigned(31 downto 0);	-- the next level's descriptor
	signal upd_table : std_logic;				-- the update is for a table descriptor
	signal desc : std_logic_vector(31 downto 0);
	signal w_la : std_logic_vector(31 downto 0);
	signal w_super, w_wr, w_test : std_logic;
	signal wp, invalid, sviol : std_logic;
	signal upd_data : std_logic_vector(15 downto 0);
	signal fault_r, done_r : std_logic := '0';
	signal mmusr_r : std_logic_vector(31 downto 0) := (others => '0');

	-- lookup results
	signal tt_hit, atc_hit, atc_need_m, atc_fault, need_walk : std_logic;
	signal hit_pp : std_logic_vector(19 downto 0);

	function tt_match(tt : std_logic_vector(31 downto 0); a : std_logic_vector(31 downto 0);
					  s : std_logic) return boolean is
		variable m : boolean := true;
	begin
		if tt(15) = '0' then
			return false;
		end if;
		for i in 0 to 7 loop
			if tt(16 + i) = '0' and tt(24 + i) /= a(24 + i) then
				m := false;
			end if;
		end loop;
		-- S field: 00 user only, 01 supervisor only, 1x both
		if tt(14) = '0' and tt(13) /= s then
			m := false;
		end if;
		return m;
	end function;

	function page_of(a : std_logic_vector(31 downto 0); p : std_logic) return std_logic_vector is
	begin
		if p = '1' then
			return a(31 downto 13) & '0';		-- 8 Kbyte pages
		end if;
		return a(31 downto 12);
	end function;
begin
	-- lookup of the core's access
	process (act, laddr, wr, fc, tc_e, tc_p, itt0, itt1, dtt0, dtt1, e_valid, e_super, e_lp, e_pp,
			 e_w, e_m, e_s, e_inv)
		variable hit : std_logic;
		variable idx : integer range 0 to N - 1;
		variable pg : std_logic_vector(19 downto 0);
	begin
		tt_hit <= '0';
		if fc(1 downto 0) = "10" then
			if tt_match(itt0, laddr, fc(2)) or tt_match(itt1, laddr, fc(2)) then tt_hit <= '1'; end if;
		else
			if tt_match(dtt0, laddr, fc(2)) or tt_match(dtt1, laddr, fc(2)) then tt_hit <= '1'; end if;
		end if;
		pg := page_of(laddr, tc_p);
		hit := '0';
		idx := 0;
		for i in 0 to N - 1 loop
			if e_valid(i) = '1' and e_super(i) = fc(2) and e_lp(i) = unsigned(pg) then
				hit := '1';
				idx := i;
			end if;
		end loop;
		atc_hit <= hit;
		hit_pp <= std_logic_vector(e_pp(idx));
		-- a write to a page whose M bit is clear goes through the tables
		atc_need_m <= wr and not e_m(idx) and not e_w(idx) and not e_inv(idx);
		atc_fault <= e_inv(idx) or (wr and e_w(idx)) or (e_s(idx) and not fc(2));
	end process;

	need_walk <= '1' when act = '1' and tc_e = '1' and tt_hit = '0' and
						  (atc_hit = '0' or (atc_need_m = '1' and atc_fault = '0')) else '0';
	stall <= '1' when need_walk = '1' or (ws /= W_IDLE and w_test = '0') else '0';
	quiet <= '1' when act = '1' and tc_e = '1' and tt_hit = '0' and atc_hit = '1' and atc_fault = '1' else '0';

	paddr <= laddr when tc_e = '0' or tt_hit = '1' else
			 hit_pp(19 downto 1) & laddr(12 downto 0) when tc_p = '1' else
			 hit_pp & laddr(11 downto 0);

	fault <= fault_r;
	ptest_done <= done_r;
	mmusr <= mmusr_r;

	bus_act <= '1' when ws = W_RD_H or ws = W_RD_L or ws = W_UPD else '0';
	bus_addr <= std_logic_vector(w_addr + 2) when ws = W_RD_L or ws = W_UPD else std_logic_vector(w_addr);
	bus_wr <= '1' when ws = W_UPD else '0';
	bus_wdata <= upd_data;

	process (clk)
		variable d : std_logic_vector(31 downto 0);
		variable nu : std_logic_vector(15 downto 0);
		variable wrp : std_logic;
	begin
		if rising_edge(clk) then
			if reset = '1' then
				ws <= W_IDLE;
				e_valid <= (others => '0');
				fault_r <= '0';
				done_r <= '0';
				w_test <= '0';
			elsif clkena = '1' then
				fault_r <= '0';
				done_r <= '0';
				if pflush = '1' then
					for i in 0 to N - 1 loop
						if pflush_all = '1' or e_g(i) = '0' then
							e_valid(i) <= '0';
						end if;
					end loop;
				end if;
				-- an access that hits a faulting entry
				if act = '1' and tc_e = '1' and tt_hit = '0' and atc_hit = '1' and atc_fault = '1' and ws = W_IDLE then
					fault_r <= '1';
				end if;
				case ws is
				when W_IDLE =>
					if ptest = '1' then
						w_la <= ptest_addr; w_super <= ptest_fc(2); w_wr <= ptest_wr; w_test <= '1';
						if (ptest_fc(1 downto 0) = "10" and (tt_match(itt0, ptest_addr, ptest_fc(2)) or
															  tt_match(itt1, ptest_addr, ptest_fc(2)))) or
						   (ptest_fc(1 downto 0) /= "10" and (tt_match(dtt0, ptest_addr, ptest_fc(2)) or
															   tt_match(dtt1, ptest_addr, ptest_fc(2)))) then
							mmusr_r <= x"00000003";			-- T and R (3.1.4)
							done_r <= '1';
						else
							if ptest_fc(2) = '1' then d := srp; else d := urp; end if;
							w_addr <= unsigned(d(31 downto 9) & ptest_addr(31 downto 25) & "00");
							lvl <= 0; wp <= '0'; invalid <= '0'; sviol <= '0';
							ws <= W_RD_H;
						end if;
					elsif need_walk = '1' then
						w_la <= laddr; w_super <= fc(2); w_wr <= wr; w_test <= '0';
						if fc(2) = '1' then d := srp; else d := urp; end if;
						w_addr <= unsigned(d(31 downto 9) & laddr(31 downto 25) & "00");
						lvl <= 0; wp <= '0'; invalid <= '0'; sviol <= '0';
						ws <= W_RD_H;
					end if;
				when W_RD_H =>
					desc(31 downto 16) <= data_in;
					ws <= W_RD_L;
				when W_RD_L =>
					desc(15 downto 0) <= data_in;
					ws <= W_CHECK;
				when W_CHECK =>
					d := desc;
					if lvl < 2 then
						-- root or pointer table descriptor: UDT 1x resident
						if d(1) = '0' then
							invalid <= '1';
							ws <= W_FILL;
						else
							wp <= wp or d(2);
							if lvl = 0 then
								next_addr <= unsigned(d(31 downto 9) & w_la(24 downto 18) & "00");
							elsif tc_p = '1' then
								next_addr <= unsigned(d(31 downto 7) & w_la(17 downto 13) & "00");
							else
								next_addr <= unsigned(d(31 downto 8) & w_la(17 downto 12) & "00");
							end if;
							lvl <= lvl + 1;
							if d(3) = '0' and w_test = '0' then
								-- set U in this descriptor, then read the next level
								upd_data <= d(15 downto 4) & '1' & d(2 downto 0);
								upd_table <= '1';
								ws <= W_UPD;
							else
								if lvl = 0 then
									w_addr <= unsigned(d(31 downto 9) & w_la(24 downto 18) & "00");
								elsif tc_p = '1' then
									w_addr <= unsigned(d(31 downto 7) & w_la(17 downto 13) & "00");
								else
									w_addr <= unsigned(d(31 downto 8) & w_la(17 downto 12) & "00");
								end if;
								ws <= W_RD_H;
							end if;
						end if;
					else
						-- page descriptor: PDT 00 invalid, 10 indirect, else resident
						if d(1 downto 0) = "00" then
							invalid <= '1';
							ws <= W_FILL;
						elsif d(1 downto 0) = "10" and lvl = 2 then
							w_addr <= unsigned(d(31 downto 2) & "00");
							lvl <= 3;
							ws <= W_RD_H;
						elsif d(1 downto 0) = "10" then
							invalid <= '1';						-- indirect to indirect
							ws <= W_FILL;
						else
							wrp := wp or d(2);
							wp <= wrp;
							if d(7) = '1' and w_super = '0' then
								sviol <= '1';
							end if;
							-- table 3-1: set U, and M for a write that is allowed
							nu := d(15 downto 0);
							nu(3) := '1';
							if w_wr = '1' and wrp = '0' and not (d(7) = '1' and w_super = '0') then
								nu(4) := '1';
							end if;
							if nu /= d(15 downto 0) and w_test = '0' then
								upd_data <= nu;
								upd_table <= '0';
								desc(15 downto 0) <= nu;
								ws <= W_UPD;
							else
								ws <= W_FILL;
							end if;
						end if;
					end if;
				when W_UPD =>
					-- the low word of the descriptor is written back
					if upd_table = '1' then
						w_addr <= next_addr;
						ws <= W_RD_H;
					else
						ws <= W_FILL;
					end if;
				when W_FILL =>
					-- load the cache; a faulting translation is cached too, so the
					-- access completes quietly and reports the fault
					d := desc;
					e_valid(victim) <= '1';
					e_super(victim) <= w_super;
					e_lp(victim) <= unsigned(page_of(w_la, tc_p));
					e_pp(victim) <= unsigned(d(31 downto 12));
					e_w(victim) <= wp;
					e_m(victim) <= d(4);
					e_s(victim) <= d(7);
					e_g(victim) <= d(10);
					e_inv(victim) <= invalid;
					if victim = N - 1 then victim <= 0; else victim <= victim + 1; end if;
					if w_test = '1' then
						if invalid = '1' then
							mmusr_r <= (2 => wp, others => '0');
						else
							mmusr_r <= d(31 downto 12) & '0' & d(10) & d(9) & d(8) & d(7) & d(6) & d(5) &
									   d(4) & '0' & wp & '0' & '1';
						end if;
						done_r <= '1';
					end if;
					ws <= W_DONE;
				when W_DONE =>
					w_test <= '0';
					ws <= W_IDLE;
				end case;
			end if;
		end if;
	end process;
end architecture;
