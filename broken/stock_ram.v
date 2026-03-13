`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// stock_ram  (sync read) -> here sync read means that the data is only available on the next clock cycle after providing the address
// ---------------------------------------------------------------------------
module stock_ram #(
    parameter ITEM_COUNT = 7, // default value of 7 items, can be overridden when instantiating
    parameter ADDR_W = 3,
    parameter DATA_W = 16
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [ADDR_W-1:0]    rd_addr,
    output reg  [DATA_W-1:0]    rd_data,
    input  wire                 wr_en,
    input  wire [ADDR_W-1:0]    wr_addr,
    input  wire [DATA_W-1:0]    wr_data
);
    reg [DATA_W-1:0] mem [0:ITEM_COUNT-1]; // reg[15:0] mem[0:6]  => 7 items with 16-bit stock count each
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i=0;i<ITEM_COUNT;i=i+1) mem[i] <= {DATA_W{1'b0}}; // initialize all stock counts to 0 on reset
            rd_data <= {DATA_W{1'b0}}; // also reset the output data to 0
        end else begin
            rd_data <= mem[rd_addr]; 
            if (wr_en) mem[wr_addr] <= wr_data;
        end
    end
endmodule

