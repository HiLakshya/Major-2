`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// price_table  (sync read)
// ---------------------------------------------------------------------------
module price_table #(
    parameter ITEM_COUNT = 7,
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
    reg [DATA_W-1:0] mem [0:ITEM_COUNT-1];
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin  // reset all prices to 0
            for (i=0;i<ITEM_COUNT;i=i+1) mem[i] <= {DATA_W{1'b0}};
            rd_data <= {DATA_W{1'b0}};
        end else begin // synchronous read/write
            rd_data <= mem[rd_addr];
            if (wr_en) mem[wr_addr] <= wr_data;
        end
    end
endmodule

