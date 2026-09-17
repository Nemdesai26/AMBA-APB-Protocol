`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 26.01.2026 13:43:51
// Design Name: 
// Module Name: apb_master
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


module apb_master(
input [8:0] apb_write_paddr,
input [7:0] apb_write_data,
input [8:0] apb_read_paddr,
input [7:0] prdata,  //
input presetn,  //
input pclk,  // 
input read,
input write,
input transfer,
input pready,
input pslverr,
output reg psel1,psel2,
output reg penable,
output reg [8:0] paddr,
output reg pwrite,
output reg [7:0] pwdata,
output reg error,   //new
output reg [7:0] apb_read_data_out   //new

    );
    reg [1:0] present_state,next_state;
    parameter idle =2'b00;
    parameter setup =2'b01;
    parameter enable =2'b10;
    
    always @(posedge pclk or negedge presetn)
    begin
    
    if(presetn==0)
    begin
    present_state<=idle;
    end
    
    else 
    begin
    present_state<=next_state;
    end
    
    end
    
    
    always @(*)
    begin
    next_state = present_state; 
    
    case(present_state)
    
    idle:
    begin
    if(transfer==0)
    next_state=idle;
    else
    next_state=setup;
    end
    
    setup:
    begin
    next_state=enable;
    end
    
    enable:
    begin
       // if(psel1||psel2)
        //begin
                if(pready)
                begin
                    if(transfer && !pslverr)
                    begin
                    next_state=setup;
                    end
                    else
                    next_state=idle;
                end
                else 
                    next_state=enable;
        end
        //else
        //next_state=idle;
        //end
        default:next_state=idle;
    endcase
    end


always @(posedge pclk or negedge presetn)
begin
    if(!presetn)
        error <= 1'b0;
    else if (present_state == enable && pready && pslverr)
        error <= 1'b1;
    else
        error <= 1'b0;
end




always @(posedge pclk or negedge presetn)
begin
if(presetn==0)
begin
psel1<=0;
psel2<=0;
penable<=0;
paddr <=0;
pwdata <=0;
pwrite <=0;
apb_read_data_out<=0;
end

else
begin

case(present_state)

idle:
begin
penable <=0;
pwrite<=0;
psel1<=0;
psel2<=0;
end

setup:
begin
penable<=1'b0;
if(write==1 && read==0)
    begin
    paddr<=apb_write_paddr;
    pwdata<=apb_write_data;
    pwrite<=1'b1;
    
    if(apb_write_paddr[8]==1)
        begin
        psel2<=1;
        psel1<=0;
        end
    else
        begin
        psel2<=0;
        psel1<=1;
        end
end
else if(write==0 && read==1)
    begin
    paddr<=apb_read_paddr;
    pwrite<=1'b0;
    if(apb_read_paddr[8]==1)
        begin
        psel2<=1;
        psel1<=0;
        end
    else
        begin
        psel1<=1;
        psel2<=0;
    end
end
else
    begin
    psel1<=0;
    psel2<=0;
end
end


enable:
begin
penable<=1'b1;
if(pready==1 && pwrite==0)
apb_read_data_out<=prdata;
end
endcase
end
end
endmodule
