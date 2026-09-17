`timescale 1ns / 1ps

//  Layers:
//    L1  Interface          signal bundle + SVA assertions
//    L2  Driver             atomic APB read / write tasks
//    L3  Scoreboard         shadow memory + pass/fail checker
//    L4  Test sequences     named test tasks, clean & readable
//    L5  Top module         DUT wiring, clock, reset, summary
//

interface apb_if (input logic pclk);

    // Stimulus (TB drives)
    logic        presetn;
    logic        transfer;
    logic        read;
    logic        write;
    logic [8:0]  apb_write_paddr;
    logic [7:0]  apb_write_data;
    logic [8:0]  apb_read_paddr;
    logic        wait_cycle_slave1;
    logic        wait_cycle_slave2;

    // DUT outputs (TB observes)
    logic        pslverr;
    logic        error;
    logic [7:0]  apb_read_data_out;

    // Internal DUT signals tapped for SVA + monitor
    logic        penable;
    logic        pwrite;
    logic [8:0]  paddr;
    logic [7:0]  pwdata;
    logic        pready;
    logic        psel1;
    logic        psel2;
    logic [1:0]  fsm_state;   // master present_state

    // --------------------------------------------------------
    // SVA ASSERTIONS
    // --------------------------------------------------------

    // psel1 and psel2 must never both be high
    property p_psel_mutex;
        @(posedge pclk) disable iff (!presetn)
        !(psel1 && psel2);
    endproperty
    assert property (p_psel_mutex)
        else $error("[SVA] psel1 & psel2 both high @ %0t", $time);

    // penable must follow a RISING psel on the very next cycle.
    property p_psel_to_penable;
        @(posedge pclk) disable iff (!presetn)
        $rose(psel1 | psel2) |=> penable;
    endproperty
    assert property (p_psel_to_penable)
        else $error("[SVA] penable did not follow psel @ %0t", $time);

    // paddr must be stable for the entire enable phase
    property p_paddr_stable;
        @(posedge pclk) disable iff (!presetn)
        penable |-> $stable(paddr);
    endproperty
    assert property (p_paddr_stable)
        else $error("[SVA] paddr changed during enable phase @ %0t", $time);

endinterface : apb_if

class apb_driver;

    virtual apb_if vif;

    function new(virtual apb_if v);
        vif = v;
    endfunction

    // -------------------------------------------------------
    // wait_for_idle  -  polls FSM state, not output signals
    // -------------------------------------------------------
    task wait_for_idle();
        int timeout = 0;
        while (vif.fsm_state !== 2'b00 && timeout < 60) begin
            @(posedge vif.pclk);
            timeout++;
        end
        if (timeout >= 60)
            $display("[DRV] WARNING: FSM idle timeout @ %0t", $time);
        @(posedge vif.pclk); // one extra settling cycle
    endtask

    task drive_write(
        input  logic [8:0] addr,
        input  logic [7:0] data,
        input  logic       ws1,
        input  logic       ws2,
        output logic       error_seen
    );
        error_seen = 0;

        vif.wait_cycle_slave1 = ws1;
        vif.wait_cycle_slave2 = ws2;
        vif.apb_write_paddr   = addr;
        vif.apb_write_data    = data;
        vif.write             = 1;
        vif.read              = 0;
        vif.transfer          = 0;

        @(posedge vif.pclk); #1;
        vif.transfer = 1;

        // Hold transfer until FSM leaves IDLE
        while (vif.fsm_state == 2'b00)
            @(posedge vif.pclk);
        #1;
        vif.transfer = 0;
        vif.write    = 0;

        // Spin until ENABLE phase (2'b10) or back to IDLE
        // (IDLE means transaction was very fast, already done)
        while (vif.fsm_state !== 2'b10 && vif.fsm_state !== 2'b00)
            @(posedge vif.pclk);

        // If we caught the ENABLE phase, sample on the next edge
        // when registered error output is valid
        if (vif.fsm_state == 2'b10) begin
            @(posedge vif.pclk); #1;
            error_seen = vif.pslverr | vif.error;
        end

        wait_for_idle();

        // Second chance: some masters register error one cycle after idle
        if (!error_seen)
            error_seen = vif.error;
    endtask

    // drive_read  -  same pattern as drive_write
    task drive_read(
        input  logic [8:0] addr,
        input  logic       ws1,
        input  logic       ws2,
        output logic [7:0] rdata,
        output logic       error_seen
    );
        error_seen = 0;

        vif.wait_cycle_slave1 = ws1;
        vif.wait_cycle_slave2 = ws2;
        vif.apb_read_paddr    = addr;
        vif.read              = 1;
        vif.write             = 0;
        vif.transfer          = 0;

        @(posedge vif.pclk); #1;
        vif.transfer = 1;

        while (vif.fsm_state == 2'b00)
            @(posedge vif.pclk);
        #1;
        vif.transfer = 0;
        vif.read     = 0;

        while (vif.fsm_state !== 2'b10 && vif.fsm_state !== 2'b00)
            @(posedge vif.pclk);

        if (vif.fsm_state == 2'b10) begin
            @(posedge vif.pclk); #1;
            error_seen = vif.pslverr | vif.error;
        end

        wait_for_idle();
        if (!error_seen)
            error_seen = vif.error;

        rdata = vif.apb_read_data_out;
    endtask

endclass : apb_driver

class apb_scoreboard;

    logic [7:0] mem_s1 [0:255];
    logic [7:0] mem_s2 [0:255];
    int pass_count = 0;
    int fail_count = 0;

    function new();
        foreach (mem_s1[i]) mem_s1[i] = 8'hxx;
        foreach (mem_s2[i]) mem_s2[i] = 8'hxx;
    endfunction

    function void record_write(
        input logic [8:0] addr,
        input logic [7:0] data,
        input logic       err
    );
        if (err) return;
        if      (addr[8] == 0 && addr[7:0] <= 8'hEF) mem_s1[addr[7:0]] = data;
        else if (addr[8] == 1 && addr[7:0] <= 8'hEF) mem_s2[addr[7:0]] = data;
    endfunction

    function void check_read(
        input logic [8:0] addr,
        input logic [7:0] actual,
        input logic       err
    );
        logic [7:0] expected;
        if (err) begin
            $display("[SB ] addr=0x%03h  slave error, skip check", addr);
            return;
        end
        expected = (addr[8] == 0) ? mem_s1[addr[7:0]] : mem_s2[addr[7:0]];
        if (expected === 8'hxx) begin
            $display("[SB ] addr=0x%03h  got=0x%02h  not yet written (skip)", addr, actual);
            return;
        end
        if (actual === expected) begin
            $display("[SB ] addr=0x%03h  got=0x%02h  exp=0x%02h  PASS ✓", addr, actual, expected);
            pass_count++;
        end else begin
            $display("[SB ] addr=0x%03h  got=0x%02h  exp=0x%02h  FAIL ✗", addr, actual, expected);
            fail_count++;
        end
    endfunction

endclass : apb_scoreboard


class apb_test;

    apb_driver     drv;
    apb_scoreboard sb;
    virtual apb_if vif;
    int            test_num = 0;

    function new(apb_driver d, apb_scoreboard s, virtual apb_if v);
        drv = d;  sb = s;  vif = v;
    endfunction

    // ---- Primitive helpers --------------------------------

    task do_write(
        input logic [8:0] addr,
        input logic [7:0] data,
        input logic       ws1 = 0,
        input logic       ws2 = 0
    );
        logic err;
        drv.drive_write(addr, data, ws1, ws2, err);
        if (err) $display("[MON] WRITE addr=0x%03h  slave ERROR", addr);
        sb.record_write(addr, data, err);
    endtask

    task do_read(
        input logic [8:0] addr,
        input logic       ws1 = 0,
        input logic       ws2 = 0
    );
        logic [7:0] rdata;
        logic       err;
        drv.drive_read(addr, ws1, ws2, rdata, err);
        if (err) $display("[MON] READ  addr=0x%03h  slave ERROR", addr);
        sb.check_read(addr, rdata, err);
    endtask

    task write_read(
        input logic [8:0] addr,
        input logic [7:0] data,
        input logic       ws1 = 0,
        input logic       ws2 = 0
    );
        do_write(addr, data, ws1, ws2);
        do_read (addr, ws1, ws2);
    endtask

    // Write to an address that MUST produce a slave error
    task write_expect_err(
        input logic [8:0] addr,
        input logic [7:0] data
    );
        logic err;
        drv.drive_write(addr, data, 0, 0, err);
        if (err) begin
            $display("[MON] addr=0x%03h  error flag set correctly ✓", addr);
        end else begin
            $display("[MON] addr=0x%03h  error flag NOT set ✗", addr);
            sb.fail_count++;
        end
    endtask

    // ---- Individual tests ---------------------------------

    task test_slave1_no_wait();
        test_num++;
        $display("\n--- TEST %0d: Slave1 write/read, no wait ---", test_num);
        write_read(9'h005, 8'hAA);
    endtask

    task test_slave2_no_wait();
        test_num++;
        $display("\n--- TEST %0d: Slave2 write/read, no wait ---", test_num);
        write_read(9'h105, 8'h55);
    endtask

    task test_slave1_with_wait();
        test_num++;
        $display("\n--- TEST %0d: Slave1 write/read, with wait ---", test_num);
        write_read(9'h010, 8'h77, .ws1(1));
    endtask

    task test_slave2_with_wait();
        test_num++;
        $display("\n--- TEST %0d: Slave2 write/read, with wait ---", test_num);
        write_read(9'h120, 8'h33, .ws2(1));
    endtask

    task test_both_wait();
        test_num++;
        $display("\n--- TEST %0d: Both slaves with wait ---", test_num);
        write_read(9'h015, 8'hBB, .ws1(1), .ws2(1));
        write_read(9'h115, 8'hCC, .ws1(1), .ws2(1));
    endtask

    task test_invalid_slave1();
        test_num++;
        $display("\n--- TEST %0d: Invalid addr Slave1 (pslverr expected) ---", test_num);
        write_expect_err(9'h0F5, 8'hFF);
    endtask

    task test_invalid_slave2();
        test_num++;
        $display("\n--- TEST %0d: Invalid addr Slave2 (pslverr expected) ---", test_num);
        write_expect_err(9'h1FA, 8'hEE);
    endtask

    task test_multi_slave1();
        test_num++;
        $display("\n--- TEST %0d: Multiple writes Slave1, read all back ---", test_num);
        do_write(9'h020, 8'h11);
        do_write(9'h021, 8'h22);
        do_write(9'h022, 8'h44);
        do_write(9'h023, 8'h88);
        do_read (9'h020);
        do_read (9'h021);
        do_read (9'h022);
        do_read (9'h023);
    endtask

    task test_multi_slave2();
        test_num++;
        $display("\n--- TEST %0d: Multiple writes Slave2, read all back ---", test_num);
        do_write(9'h130, 8'hAB);
        do_write(9'h131, 8'hCD);
        do_write(9'h132, 8'hEF);
        do_read (9'h130);
        do_read (9'h131);
        do_read (9'h132);
    endtask

    task test_overwrite();
        test_num++;
        $display("\n--- TEST %0d: Overwrite Slave1 addr 0x005, verify ---", test_num);
        do_write(9'h005, 8'h11);
        do_read (9'h005);
    endtask

    task test_boundary_slave1();
        test_num++;
        $display("\n--- TEST %0d: Boundary Slave1, last valid addr 0x0EF ---", test_num);
        write_read(9'h0EF, 8'h5A);
    endtask

    task test_boundary_slave2();
        test_num++;
        $display("\n--- TEST %0d: Boundary Slave2, last valid addr 0x1EF ---", test_num);
        write_read(9'h1EF, 8'hA5);
    endtask

    task test_read_wait_slave1();
        test_num++;
        $display("\n--- TEST %0d: Read Slave1 with wait ---", test_num);
        do_write(9'h030, 8'h99);
        do_read (9'h030, .ws1(1));
    endtask

    task test_read_wait_slave2();
        test_num++;
        $display("\n--- TEST %0d: Read Slave2 with wait ---", test_num);
        do_write(9'h140, 8'h66);
        do_read (9'h140, .ws2(1));
    endtask

    // ---- Run all ------------------------------------------
    task run_all();
        test_slave1_no_wait();
        test_slave2_no_wait();
        test_slave1_with_wait();
        test_slave2_with_wait();
        test_both_wait();
        test_invalid_slave1();
        test_invalid_slave2();
        test_multi_slave1();
        test_multi_slave2();
        test_overwrite();
        test_boundary_slave1();
        test_boundary_slave2();
        test_read_wait_slave1();
        test_read_wait_slave2();
    endtask

endclass : apb_test

class apb_txn;

    logic        write;   // 1 = write, 0 = read
    logic [8:0]  addr;
    logic [7:0]  wdata;
    logic [7:0]  rdata;
    logic        error;

    function void display(string tag = "TXN");
        $display("[%s] write=%0d addr=0x%03h wdata=0x%02h rdata=0x%02h err=%0d @ %0t",
                  tag, write, addr, wdata, rdata, error, $time);
    endfunction

endclass : apb_txn

class apb_monitor;

    virtual apb_if vif;
    mailbox #(apb_txn) mon2sb;

    function new(virtual apb_if v, mailbox #(apb_txn) mb);
        vif    = v;
        mon2sb = mb;
    endfunction

    task run();
        apb_txn txn;

        forever begin
            @(posedge vif.pclk);

            // Detect ENABLE phase (valid transaction phase)
            if (vif.penable && vif.pready) begin

                txn = new();

                txn.write = vif.pwrite;
                txn.addr  = vif.paddr;
                txn.error = vif.pslverr | vif.error;

                if (vif.pwrite) begin
                    txn.wdata = vif.pwdata;
                end else begin
                    txn.rdata = vif.apb_read_data_out;
                end

                txn.display("MON");

                mon2sb.put(txn);
            end
        end
    endtask

endclass : apb_monitor

module apb_top_tb;

    // ---- Clock ----
    logic clk;
    initial  clk = 0;
    always #5 clk = ~clk;   // 100 MHz

    // ---- Interface ----
    apb_if intf (clk);

    // ---- DUT ----
    apb_top dut (
        .pclk               (clk),
        .presetn            (intf.presetn),
        .transfer           (intf.transfer),
        .read               (intf.read),
        .write              (intf.write),
        .apb_write_paddr    (intf.apb_write_paddr),
        .apb_write_data     (intf.apb_write_data),
        .apb_read_paddr     (intf.apb_read_paddr),
        .wait_cycle_slave1  (intf.wait_cycle_slave1),
        .wait_cycle_slave2  (intf.wait_cycle_slave2),
        .pslverr            (intf.pslverr),
        .error              (intf.error),
        .apb_read_data_out  (intf.apb_read_data_out)
    );

    // ---- Tap internal DUT signals into interface ----
    assign intf.penable   = dut.penable;
    assign intf.pwrite    = dut.pwrite;
    assign intf.paddr     = dut.paddr;
    assign intf.pwdata    = dut.pwdata;
    assign intf.pready    = dut.pready;
    assign intf.psel1     = dut.psel1;
    assign intf.psel2     = dut.psel2;
    assign intf.fsm_state = dut.master_inst.present_state;

    // ---- TB objects ----
    apb_driver     drv;
    apb_scoreboard sb;
    apb_test       tst;
    
    mailbox #(apb_txn) mon2sb;
    apb_monitor mon;

    // ---- Reset ----
    task do_reset();
        intf.presetn           = 0;
        intf.transfer          = 0;
        intf.read              = 0;
        intf.write             = 0;
        intf.apb_write_paddr   = 0;
        intf.apb_write_data    = 0;
        intf.apb_read_paddr    = 0;
        intf.wait_cycle_slave1 = 0;
        intf.wait_cycle_slave2 = 0;
        repeat(4) @(posedge clk);
        intf.presetn = 1;
        repeat(2) @(posedge clk);
        $display("[TB ] Reset complete @ %0t", $time);
    endtask

    // ---- Main ----
    initial begin
        // Full waveform dump - all signals appear in Vivado automatically
        $dumpfile("apb_tb.vcd");
        $dumpvars(0, apb_top_tb);   // 0 = recurse into every sub-module

        $display("\n============================================================");
        $display("     APB SV Testbench  (5-layer, Vivado XSim)");
        $display("============================================================\n");

        drv = new(intf);
        sb  = new();
        tst = new(drv, sb, intf);

        do_reset();
        tst.run_all();
        
        mon2sb = new();
        mon = new(intf, mon2sb);

// Start monitor in parallel
        fork
           mon.run();
        join_none

        repeat(10) @(posedge clk);

        $display("\n============================================================");
        $display("                     TEST SUMMARY");
        $display("============================================================");
        $display("  Total tests : %0d", tst.test_num);
        $display("  SB PASS     : %0d", sb.pass_count);
        $display("  SB FAIL     : %0d", sb.fail_count);
        if (sb.fail_count == 0)
            $display("  *** ALL SCOREBOARD CHECKS PASSED ✓ ***");
        else
            $display("  *** %0d SCOREBOARD CHECKS FAILED ✗ ***", sb.fail_count);
        $display("============================================================\n");

        $finish;
    end

    // ---- Watchdog ----
    initial begin
        #500_000;
        $display("[TIMEOUT] Simulation limit reached");
        $finish;
    end

endmodule : apb_top_tb