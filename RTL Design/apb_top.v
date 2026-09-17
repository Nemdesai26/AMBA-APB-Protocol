`timescale 1ns / 1ps

module apb_top (
    input wire pclk,
    input wire presetn,
    input wire transfer,
    input wire read,
    input wire write,
    input wire [8:0] apb_write_paddr,
    input wire [7:0] apb_write_data,
    input wire [8:0] apb_read_paddr,
    input wire wait_cycle_slave1,        // Wait control for slave 1
    input wire wait_cycle_slave2,        // Wait control for slave 2
    output wire pslverr,
    output wire error,                   // Master's error flag
    output wire [7:0] apb_read_data_out
);

    // Internal wires
    wire penable;
    wire pwrite;
    wire [8:0] paddr;
    wire [7:0] pwdata;
    wire [7:0] prdata1, prdata2;
    wire pready1, pready2;
    wire pslverr1, pslverr2;             // Separate error signals for slave
    wire psel1, psel2;
    
    //Mux for prdata
    wire [7:0] prdata_mux;
    assign prdata_mux = psel1 ? prdata1 : 
                        psel2 ? prdata2 : 8'h00;
    
    // MUX for pready
    wire pready;
    assign pready = psel1 ? pready1 : 
                    psel2 ? pready2 : 1'b0;
    
    //MUX for pslverr
    assign pslverr = (psel1 && pslverr1) || (psel2 && pslverr2);
    
    // Master instance
    apb_master master_inst (
        .pclk(pclk),
        .presetn(presetn),
        .transfer(transfer),
        .read(read),
        .write(write),
        .apb_write_paddr(apb_write_paddr),
        .apb_read_paddr(apb_read_paddr),
        .apb_write_data(apb_write_data),
        .pready(pready),                  //  Muxed ready
        .pslverr(pslverr),                //  Muxed error
        .prdata(prdata_mux),              // Muxed read data
        .psel1(psel1),
        .psel2(psel2),
        .penable(penable),
        .paddr(paddr),
        .pwrite(pwrite),
        .pwdata(pwdata),
        .error(error),                    // Master's error output
        .apb_read_data_out(apb_read_data_out)
    );
    
    // Slave 1 instance
    apb_slave slave1_inst (
        .pclk(pclk),
        .presetn(presetn),
        .psel(psel1),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),                    //  Full 9-bit address
        .pwdata(pwdata),
        .wait_cycle(wait_cycle_slave1),   //  Connected
        .prdata(prdata1),
        .pready(pready1),
        .pslverr(pslverr1)                // Separate signal
    );
    
    // Slave 2 instance
    apb_slave slave2_inst (
        .pclk(pclk),
        .presetn(presetn),
        .psel(psel2),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),                    //  Full 9-bit address
        .pwdata(pwdata),
        .wait_cycle(wait_cycle_slave2),   //  Connected
        .prdata(prdata2),
        .pready(pready2),
        .pslverr(pslverr2)                //  Separate signal
    );

endmodule