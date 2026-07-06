module apb_master (
  input  wire clk,
  input  wire rst_n,

  // 控制接口
  input  wire        wr_req,
  input  wire [31:0] wr_addr,
  input  wire [31:0] wr_data,
  output reg         wr_ack,

  input  wire        rd_req,
  input  wire [31:0] rd_addr,
  output reg  [31:0] rd_data,
  output reg         rd_ack,

  // APB信号
  output reg         psel,
  output reg         penable,
  output reg         pwrite,
  output reg  [31:0] paddr,
  output reg  [31:0] pwdata,
  input  wire [31:0] prdata,
  input  wire        pready,
  input  wire        pslverr
);

// 状态机定义
localparam IDLE  = 3'd0;
localparam SETUP = 3'd1;
localparam ACCESS= 3'd2;

reg [2:0] state, next_state;

reg wr_req_r;
reg rd_req_r;

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    state <= IDLE;
    wr_ack <= 0;
    rd_ack <= 0;
    psel <= 0;
    penable <= 0;
  end else begin
    state <= next_state;

    if (state == ACCESS && pready) begin
      psel <= 0;
      penable <= 0;

      if (pwrite)
        wr_ack <= ~pslverr;
      else
        rd_ack <= ~pslverr;

    end else if (state == SETUP) begin
      psel <= 1;
      penable <= 0;
      wr_ack <= 0;
      rd_ack <= 0;
    end else if (state == IDLE) begin
      psel <= 0;
      penable <= 0;
      wr_ack <= 0;
      rd_ack <= 0;
    end
  end
end

always @(*) begin
  next_state = state;
  case(state)
    IDLE: begin
      if (wr_req)
        next_state = SETUP;
      else if (rd_req)
        next_state = SETUP;
    end
    SETUP: begin
      next_state = ACCESS;
    end
    ACCESS: begin
      if (pready)
        next_state = IDLE;
    end
  endcase
end

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    pwrite <= 0;
    paddr <= 0;
    pwdata <= 0;
    wr_req_r <= 0;
    rd_req_r <= 0;
    rd_data <= 32'd0;
  end else if (state == IDLE) begin
    // 采样请求信号
    wr_req_r <= wr_req;
    rd_req_r <= rd_req;
    if (wr_req)
      pwrite <= 1;
    else if (rd_req)
      pwrite <= 0;

    if (wr_req)
      paddr <= wr_addr;
    else if (rd_req)
      paddr <= rd_addr;

    if (wr_req)
      pwdata <= wr_data;
  end else if (state == ACCESS) begin
    if (pready && !pwrite) begin
      rd_data <= prdata;
    end
  end
end

endmodule