`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 26.01.2026 21:52:23
// Design Name: 
// Module Name: apb_slave
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module apb_slave(
input pclk,
input presetn,
input psel,
input penable,
input pwrite,
input [8:0]paddr,
input [7:0]pwdata,
input wait_cycle,
output reg [7:0] prdata,
output reg pready,
output reg pslverr


    );
    reg[7:0]mem[255:0];
    reg wait_op;
    parameter addr_max=8'hEF;
    
    always @(posedge pclk or negedge presetn)
    begin
    if(!presetn)
    begin
    pready<=0;
    pslverr<=0;
    prdata<=8'h00;
    wait_op <=1'b0;
    end
    
    else
    begin
    pslverr<=1'b0;
    if(psel&&!penable)
    begin 
    pready<=1'b0;
    wait_op<=wait_cycle;
        if(!pwrite)
        begin
            if(paddr[7:0]<=addr_max)
            begin
            prdata<=mem[paddr[7:0]];
            end
            else
            begin
            prdata<=8'h00;
            end
        end
    end
    else if(psel && penable)
    begin
        if(wait_op==0)
        begin
        pready<=1'b1;
            if(paddr[7:0]>addr_max)
            begin
            pslverr<=1'b1;
            end
            
            else
            begin
                if(pwrite)
                begin
                mem[paddr[7:0]]<=pwdata;
                end
            end
        end
        else
        begin
        wait_op<=0;
        //wait_op<=wait_op-1; for more than 1 wait cycles.for this change wait_op,wait_cycle as well for proper functionality
        pready<=1'b0;    
        end
        end
    else
    begin
    pready<=1'b0;
    wait_op<=1'b0;
    end
    
    end
    end
endmodule
