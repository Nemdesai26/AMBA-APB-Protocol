`timescale 1ns / 1ps

module apb_top_tb;

    // ========================================
    // Testbench Signals
    // ========================================
    reg pclk;
    reg presetn;
    reg transfer;
    reg read;
    reg write;
    reg [8:0] apb_write_paddr;
    reg [7:0] apb_write_data;
    reg [8:0] apb_read_paddr;
    reg wait_cycle_slave1;
    reg wait_cycle_slave2;
    
    wire pslverr;
    wire error;
    wire [7:0] apb_read_data_out;
    
    // Test control variables
    integer test_num;
    integer errors;
    integer timeout_count;
    
    // ========================================
    // DUT Instantiation
    // ========================================
    apb_top dut (
        .pclk(pclk),
        .presetn(presetn),
        .transfer(transfer),
        .read(read),
        .write(write),
        .apb_write_paddr(apb_write_paddr),
        .apb_write_data(apb_write_data),
        .apb_read_paddr(apb_read_paddr),
        .wait_cycle_slave1(wait_cycle_slave1),
        .wait_cycle_slave2(wait_cycle_slave2),
        .pslverr(pslverr),
        .error(error),
        .apb_read_data_out(apb_read_data_out)
    );
    
    // ========================================
    // Clock Generation - 10ns period (100MHz)
    // ========================================
    initial begin
        pclk = 0;
        forever #5 pclk = ~pclk;
    end
    
    // ========================================
    // Task: Reset System
    // ========================================
    task reset_system;
        begin
            $display("\n[%0t] === RESET SYSTEM ===", $time);
            presetn = 0;
            transfer = 0;
            read = 0;
            write = 0;
            apb_write_paddr = 0;
            apb_write_data = 0;
            apb_read_paddr = 0;
            wait_cycle_slave1 = 0;
            wait_cycle_slave2 = 0;
            #30;
            presetn = 1;
            #20;
        end
    endtask
    
    // ========================================
    // Task: Wait for Transaction Complete
    // ========================================
    task wait_transaction_complete;
        begin
            timeout_count = 0;
            // Wait for FSM to go back to IDLE
            while (dut.master_inst.present_state != 2'b00 && timeout_count < 100) begin
                @(posedge pclk);
                timeout_count = timeout_count + 1;
            end
            
            if (timeout_count >= 100) begin
                $display("[%0t]   ERROR: Transaction timeout! FSM stuck in state %b", 
                         $time, dut.master_inst.present_state);
                errors = errors + 1;
            end
            
            @(posedge pclk); // Extra cycle for stability
        end
    endtask
    
    // ========================================
    // Task: Write to APB (CORRECTED)
    // ========================================
    task apb_write(
        input [8:0] addr,
        input [7:0] data
    );
        begin
            $display("[%0t] WRITE: Addr=0x%h, Data=0x%h", $time, addr, data);
            
            // Setup inputs BEFORE asserting transfer
            apb_write_paddr = addr;
            apb_write_data = data;
            write = 1;
            read = 0;
            transfer = 0;
            
            @(posedge pclk);  // Wait for setup
            #1;  // Small delay after clock edge
            transfer = 1;  // Assert transfer
            
            // Keep transfer high until FSM leaves IDLE
            while (dut.master_inst.present_state == 2'b00) begin
                @(posedge pclk);
            end
            
            // Now clear transfer
            #1;
            transfer = 0;
            write = 0;
            
            // Wait for transaction to complete
            wait_transaction_complete();
            
            if (error && pslverr)
                $display("[%0t]   SLAVE ERROR DETECTED (pslverr=1)", $time);
        end
    endtask
    
    // ========================================
    // Task: Read from APB (CORRECTED)
    // ========================================
    task apb_read(
        input [8:0] addr,
        input [7:0] expected_data,
        input check_data
    );
        begin
            $display("[%0t] READ:  Addr=0x%h, Expected=0x%h", $time, addr, expected_data);
            
            // Setup inputs BEFORE asserting transfer
            apb_read_paddr = addr;
            read = 1;
            write = 0;
            transfer = 0;
            
            @(posedge pclk);  // Wait for setup
            #1;
            transfer = 1;  // Assert transfer
            
            // Keep transfer high until FSM leaves IDLE
            while (dut.master_inst.present_state == 2'b00) begin
                @(posedge pclk);
            end
            
            // Now clear transfer
            #1;
            transfer = 0;
            read = 0;
            
            // Wait for transaction to complete
            wait_transaction_complete();
            
            // Check read data
            if (check_data) begin
                if (apb_read_data_out === expected_data) begin
                    $display("[%0t]   READ DATA: 0x%h - PASS ✓", $time, apb_read_data_out);
                end else begin
                    $display("[%0t]   READ DATA: 0x%h - FAIL ✗ (Expected 0x%h)", 
                             $time, apb_read_data_out, expected_data);
                    errors = errors + 1;
                end
            end else begin
                $display("[%0t]   READ DATA: 0x%h (not checked)", $time, apb_read_data_out);
            end
            
            if (error && pslverr)
                $display("[%0t]   SLAVE ERROR DETECTED (pslverr=1)", $time);
        end
    endtask
    
    // ========================================
    // Task: Back-to-back Writes (CORRECTED)
    // ========================================
    task apb_write_burst(
        input [8:0] addr1,
        input [7:0] data1,
        input [8:0] addr2,
        input [7:0] data2
    );
        begin
            $display("[%0t] BURST WRITE: [0x%h]=0x%h, [0x%h]=0x%h", 
                     $time, addr1, data1, addr2, data2);
            
            // First write setup
            apb_write_paddr = addr1;
            apb_write_data = data1;
            write = 1;
            read = 0;
            transfer = 0;
            
            @(posedge pclk);
            #1;
            transfer = 1;
            
            // Wait for first transaction to complete (pready=1)
            while (dut.master_inst.present_state != 2'b10) @(posedge pclk); // Wait for ENABLE
            while (!dut.pready) @(posedge pclk);  // Wait for pready
            
            @(posedge pclk);
            
            // Second write (transfer stays high for back-to-back)
            #1;
            apb_write_paddr = addr2;
            apb_write_data = data2;
            
            // Wait for second transaction to complete
            while (dut.master_inst.present_state != 2'b10) @(posedge pclk); // Wait for ENABLE
            while (!dut.pready) @(posedge pclk);  // Wait for pready
            
            @(posedge pclk);
            #1;
            transfer = 0;
            write = 0;
            
            // Return to IDLE
            wait_transaction_complete();
        end
    endtask
    
    // ========================================
    // Task: Invalid Operation (CORRECTED)
    // ========================================
    task apb_invalid_operation;
        begin
            $display("[%0t] INVALID: Both read=1 and write=1", $time);
            
            read = 1;
            write = 1;
            apb_write_paddr = 9'h010;
            transfer = 0;
            
            @(posedge pclk);
            #1;
            transfer = 1;
            
            // Keep transfer high until FSM tries to transition
            while (dut.master_inst.present_state == 2'b00) @(posedge pclk);
            
            @(posedge pclk);
            #1;
            transfer = 0;
            read = 0;
            write = 0;
            
            wait_transaction_complete();
            
            $display("[%0t]   Invalid operation completed", $time);
        end
    endtask
    
    // ========================================
    // Main Test Sequence
    // ========================================
    initial begin
        test_num = 0;
        errors = 0;
        
        // Waveform dump
        $dumpfile("apb_system_test.vcd");
        $dumpvars(0, apb_top_tb);
        
        $display("\n");
        $display("================================================================");
        $display("       APB MASTER-SLAVE COMPREHENSIVE TESTBENCH");
        $display("       (Final Corrected Version)");
        $display("================================================================");
        
        // Initialize
        reset_system();
        
        // ========================================
        // TEST 1: Write to Slave 1 (No Wait State)
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Write to Slave 1 (addr[8]=0), No Wait ---", test_num);
        wait_cycle_slave1 = 0;
        wait_cycle_slave2 = 0;
        apb_write(9'h005, 8'hAA);
        #50;
        
        // ========================================
        // TEST 2: Read from Slave 1 (Verify Write)
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Read from Slave 1 (Verify) ---", test_num);
        apb_read(9'h005, 8'hAA, 1);
        #50;
        
        // ========================================
        // TEST 3: Write to Slave 2 (addr[8]=1, No Wait)
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Write to Slave 2 (addr[8]=1), No Wait ---", test_num);
        apb_write(9'h105, 8'h55);
        #50;
        
        // ========================================
        // TEST 4: Read from Slave 2 (Verify Write)
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Read from Slave 2 (Verify) ---", test_num);
        apb_read(9'h105, 8'h55, 1);
        #50;
        
        // ========================================
        // TEST 5: Write to Slave 1 WITH Wait State
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Write to Slave 1 WITH 1-Cycle Wait ---", test_num);
        wait_cycle_slave1 = 1;
        apb_write(9'h010, 8'h77);
        #50;
        
        // ========================================
        // TEST 6: Read from Slave 1 WITH Wait State
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Read from Slave 1 WITH Wait (Verify) ---", test_num);
        wait_cycle_slave1 = 1;
        apb_read(9'h010, 8'h77, 1);
        #50;
        
        // ========================================
        // TEST 7: Write to Slave 2 WITH Wait State
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Write to Slave 2 WITH 1-Cycle Wait ---", test_num);
        wait_cycle_slave1 = 0;
        wait_cycle_slave2 = 1;
        apb_write(9'h120, 8'h33);
        #50;
        
        // ========================================
        // TEST 8: Read from Slave 2 WITH Wait State
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Read from Slave 2 WITH Wait (Verify) ---", test_num);
        wait_cycle_slave2 = 1;
        apb_read(9'h120, 8'h33, 1);
        #50;
        
        // ========================================
        // TEST 9: Error - Invalid Address on Slave 1
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Invalid Address Slave 1 (addr=0xF5) ---", test_num);
        wait_cycle_slave1 = 0;
        wait_cycle_slave2 = 0;
        apb_write(9'h0F5, 8'hFF);
        #20;
        if (error) begin
            $display("[%0t]   MASTER ERROR FLAG SET ✓", $time);
        end else begin
            $display("[%0t]   ERROR NOT DETECTED ✗", $time);
            errors = errors + 1;
        end
        #50;
        
        // ========================================
        // TEST 10: Error - Invalid Address on Slave 2
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Invalid Address Slave 2 (addr=0x1FA) ---", test_num);
        apb_write(9'h1FA, 8'hEE);
        #20;
        if (error) begin
            $display("[%0t]   MASTER ERROR FLAG SET ✓", $time);
        end else begin
            $display("[%0t]   ERROR NOT DETECTED ✗", $time);
            errors = errors + 1;
        end
        #50;
        
        // ========================================
        // TEST 11: Back-to-back Writes (Slave 1)
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Back-to-back Writes to Slave 1 ---", test_num);
        wait_cycle_slave1 = 0;
        apb_write_burst(9'h020, 8'h11, 9'h021, 8'h22);
        #50;
        
        // Verify both writes
        $display("  Verifying burst writes...");
        apb_read(9'h020, 8'h11, 1);
        #20;
        apb_read(9'h021, 8'h22, 1);
        #50;
        
        // ========================================
        // TEST 12: Back-to-back Writes (Slave 2)
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Back-to-back Writes to Slave 2 ---", test_num);
        wait_cycle_slave2 = 0;
        apb_write_burst(9'h130, 8'h44, 9'h131, 8'h88);
        #50;
        
        // Verify both writes
        $display("  Verifying burst writes...");
        apb_read(9'h130, 8'h44, 1);
        #20;
        apb_read(9'h131, 8'h88, 1);
        #50;
        
        // ========================================
        // TEST 13: Switch Between Slaves
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Alternate Between Slave 1 and 2 ---", test_num);
        wait_cycle_slave1 = 0;
        wait_cycle_slave2 = 0;
        
        apb_write(9'h030, 8'hAB);
        #20;
        apb_write(9'h140, 8'hCD);
        #20;
        apb_read(9'h030, 8'hAB, 1);
        #20;
        apb_read(9'h140, 8'hCD, 1);
        #50;
        
        // ========================================
        // TEST 14: Invalid Operation (read=1, write=1)
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Invalid Operation (read=1, write=1) ---", test_num);
        apb_invalid_operation();
        #50;
        
        // ========================================
        // TEST 15: Multiple Writes to Same Address
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Overwrite Same Address Multiple Times ---", test_num);
        wait_cycle_slave1 = 0;
        
        apb_write(9'h040, 8'h01);
        #20;
        apb_write(9'h040, 8'h02);
        #20;
        apb_write(9'h040, 8'h03);
        #20;
        apb_read(9'h040, 8'h03, 1);
        #50;
        
        // ========================================
        // TEST 16: Boundary Addresses
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Boundary Addresses (0x00, 0xEF) ---", test_num);
        wait_cycle_slave1 = 0;
        
        apb_write(9'h000, 8'hA0);
        #20;
        apb_write(9'h0EF, 8'hB0);
        #20;
        apb_read(9'h000, 8'hA0, 1);
        #20;
        apb_read(9'h0EF, 8'hB0, 1);
        #50;
        
        // ========================================
        // TEST 17: Mixed Wait States
        // ========================================
        test_num = test_num + 1;
        $display("\n--- TEST %0d: Slave 1 No Wait, Slave 2 With Wait ---", test_num);
        wait_cycle_slave1 = 0;
        wait_cycle_slave2 = 1;
        
        apb_write(9'h050, 8'hF1);
        #20;
        apb_write(9'h150, 8'hF2);
        #20;
        apb_read(9'h050, 8'hF1, 1);
        #20;
        apb_read(9'h150, 8'hF2, 1);
        #50;
        
        // ========================================
        // TEST SUMMARY
        // ========================================
        $display("\n");
        $display("================================================================");
        $display("                    TEST SUMMARY");
        $display("================================================================");
        $display("Total Tests: %0d", test_num);
        $display("Errors:      %0d", errors);
        
        if (errors == 0) begin
            $display("\n*** ALL TESTS PASSED ✓ ***\n");
        end else begin
            $display("\n*** %0d TESTS FAILED ✗ ***\n", errors);
        end
        $display("================================================================\n");
        
        #100;
        $finish;
    end

endmodule