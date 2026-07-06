module sync_fifo #(   
    parameter DATA_WIDTH = 8,   
    parameter ADDR_WIDTH = 4,   
    parameter FWFT_EN    = 1    // 1: First Word Fall Through; 0: Standard  
)(   
    input  wire                   clk,   
    input  wire                   rst_n,   
  
    // 写接口  
    input  wire                   wr_en,   
    input  wire [DATA_WIDTH-1:0]  wr_data,      
    output wire                   full,   
  
    // 读接口  
    input  wire                   rd_en,   
    output wire [DATA_WIDTH-1:0]  rd_data,  
    output wire                   empty,
    // 状态  
    output wire [ADDR_WIDTH:0]    data_cnt

);   
  
localparam DEPTH = 1 << ADDR_WIDTH;   
  
// -------------------------------------------------------   
// Storage RAM  
// -------------------------------------------------------   
// 综合工具会根据读逻辑将其推断为 Distributed RAM (LUTRAM)
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];   
  
// -------------------------------------------------------   
// Pointers  
// -------------------------------------------------------   
reg [ADDR_WIDTH-1:0] wr_ptr;   
reg [ADDR_WIDTH-1:0] rd_ptr;   
  
// -------------------------------------------------------   
// Valid Operations  
// -------------------------------------------------------   
wire wr_vld = wr_en & ~full;       
wire rd_vld = rd_en & ~empty;      
  
// -------------------------------------------------------   
// Data Counter  
// -------------------------------------------------------   
reg [ADDR_WIDTH:0] cnt;   
  
wire [ADDR_WIDTH:0] cnt_next =  
    ( wr_vld & ~rd_vld) ? cnt + 1'b1 :   
    (~wr_vld &  rd_vld) ? cnt - 1'b1 :   
                          cnt;   
  
always @(posedge clk or negedge rst_n) begin  
    if (!rst_n) cnt <= {(ADDR_WIDTH+1){1'b0}};   
    else        cnt <= cnt_next;   
end  
  
// -------------------------------------------------------   
// Full / Empty Flags  
// -------------------------------------------------------   
reg full_r, empty_r;   
  
always @(posedge clk or negedge rst_n) begin  
    if (!rst_n) begin  
        full_r  <= 1'b0;   
        empty_r <= 1'b1;   
    end else begin  
        full_r  <= (cnt_next == DEPTH);   
        empty_r <= (cnt_next == 0);   
    end  
end  
  
assign full  = full_r;   
assign empty = empty_r;   
  
// -------------------------------------------------------   
// Write Pointer & RAM Write Logic (分离复位)
// -------------------------------------------------------   
// 1. 指针逻辑保留异步复位
always @(posedge clk or negedge rst_n) begin  
    if (!rst_n) wr_ptr <= {ADDR_WIDTH{1'b0}};   
    else if (wr_vld) begin  
        wr_ptr <= wr_ptr + 1'b1;   
    end  
end  

// 2. RAM 写入逻辑使用纯同步块（无复位），确保推断为 RAM
always @(posedge clk) begin
    if (wr_vld) begin
        mem[wr_ptr] <= wr_data;
    end
end
  
// -------------------------------------------------------   
// Read Pointer  
// -------------------------------------------------------   
always @(posedge clk or negedge rst_n) begin  
    if (!rst_n) rd_ptr <= {ADDR_WIDTH{1'b0}};   
    else if (rd_vld)   
        rd_ptr <= rd_ptr + 1'b1;   
end  
  
// -------------------------------------------------------   
// Read Data Output  
// -------------------------------------------------------   
generate  
    if (FWFT_EN) begin : gen_fwft  
        // 异步读：结合上面的纯同步写，会被完美推断为 Distributed RAM
        assign rd_data = mem[rd_ptr];   
    end   
    else begin : gen_std  
        reg [DATA_WIDTH-1:0] rd_data_r;   
        always @(posedge clk or negedge rst_n) begin  
            if (!rst_n)      rd_data_r <= {DATA_WIDTH{1'b0}};   
            else if (rd_vld) rd_data_r <= mem[rd_ptr];   
        end  
        assign rd_data = rd_data_r;   
    end  
endgenerate  
  

assign data_cnt = cnt;   
  
endmodule