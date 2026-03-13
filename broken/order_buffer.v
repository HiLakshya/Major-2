`timescale 1ns/1ps

// ---------------------------------------------------------------------------
// order_buffer
// ---------------------------------------------------------------------------
module order_buffer #(
    parameter MAX_LINES = 7,
    parameter ITEM_ID_W = 3,
    parameter QTY_W     = 8
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    append_valid,
    input  wire [ITEM_ID_W-1:0]    append_item,
    input  wire [QTY_W-1:0]        append_qty,
    input  wire                    clear,
    output wire                    full,
    output reg  [2:0]              len,

    input  wire [2:0]              read_index,
    output reg  [ITEM_ID_W-1:0]    read_item,
    output reg  [QTY_W-1:0]        read_qty
);
    reg [ITEM_ID_W-1:0] item_mem [0:MAX_LINES-1]; // reg [2:0] item_mem [0:6] 
    reg [QTY_W-1:0]     qty_mem  [0:MAX_LINES-1]; // reg [7:0] qty_mem [0:6]

    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            len <= 0;
            for (i=0;i<MAX_LINES;i=i+1) begin
                item_mem[i] <= {ITEM_ID_W{1'b0}}; // item_mem[i] <= 3'b000
                qty_mem[i]  <= {QTY_W{1'b0}};  // qty_mem[i] <= 8'b00000000
            end
        end else begin
            if (clear) begin
                len <= 0;
                for (i=0;i<MAX_LINES;i=i+1) begin
                    item_mem[i] <= {ITEM_ID_W{1'b0}};
                    qty_mem[i]  <= {QTY_W{1'b0}};
                end
            end else if (append_valid && (len < MAX_LINES)) begin
                item_mem[len] <= append_item;
                qty_mem[len]  <= append_qty;
                len <= len + 1'b1;
            end
        end
    end

    always @(*) begin
        read_item = item_mem[read_index];
        read_qty  = qty_mem[read_index];
    end

    assign full = (len == MAX_LINES);
endmodule

