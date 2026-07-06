module uart_regs (
    input  wire         clk,
    input  wire         rst_n,

    // APB
    input  wire         psel,
    input  wire         penable,
    input  wire         pwrite,
    input  wire [31:0]  paddr,
    input  wire [31:0]  pwdata,
    output wire [31:0]  prdata,
    output wire         pready,
    output wire         pslverr,

    // UART Config
    output wire [15:0]  o_cfg_baud_div,
    output wire         o_cfg_parity_en_rx,
    output wire         o_cfg_parity_mode_rx,
    output wire         o_cfg_stop_mode_rx,
    output wire         o_cfg_parity_en_tx,
    output wire         o_cfg_parity_mode_tx,
    output wire         o_cfg_stop_mode_tx,

    // TX FIFO
    output wire         o_tx_fifo_we,
    output wire [7:0]   o_tx_fifo_wdata,
    input  wire         tx_fifo_full,
    input  wire         tx_fifo_empty,

    // RX FIFO
    output wire         o_rx_fifo_re,
    input  wire [7:0]   rx_fifo_rdata,
    input  wire         rx_fifo_empty,
    input  wire         rx_fifo_full,
    input  wire [4:0]   rx_fifo_cnt,

    // Status
    input  wire         tx_idle,
    input  wire         rx_idle,
    output wire         o_irq
);

// -------------------------------------------------------------------------
// 地址解码
// -------------------------------------------------------------------------
wire [1:0] reg_offset = paddr[3:2];

localparam ADDR_CFG    = 2'h0;
localparam ADDR_TX     = 2'h1;
localparam ADDR_RX     = 2'h2;
localparam ADDR_STATUS = 2'h3;

wire cfg_wr_hit    =  pwrite && (reg_offset == ADDR_CFG);
wire tx_wr_hit     =  pwrite && (reg_offset == ADDR_TX);
wire cfg_rd_hit    = ~pwrite && (reg_offset == ADDR_CFG);
wire rx_rd_hit     = ~pwrite && (reg_offset == ADDR_RX);
wire status_rd_hit = ~pwrite && (reg_offset == ADDR_STATUS);

wire addr_valid = cfg_wr_hit    |
                  tx_wr_hit     |
                  cfg_rd_hit    |
                  rx_rd_hit     |
                  status_rd_hit;

wire apb_access = psel & penable;

wire cfg_wr_req    = apb_access & cfg_wr_hit;
wire tx_wr_req     = apb_access & tx_wr_hit;
wire rx_rd_req     = apb_access & rx_rd_hit;
wire status_rd_req = apb_access & status_rd_hit;

// -------------------------------------------------------------------------
// TX 1/2/3 字节 burst 模式转换
// mode = 0: 1 byte
// mode = 1: 2 bytes
// mode = 2: 3 bytes
// mode = 3: 3 bytes
// -------------------------------------------------------------------------
function [1:0] tx_mode_to_byte_cnt;
    input [1:0] mode;
    begin
        case (mode)
            2'd0:    tx_mode_to_byte_cnt = 2'd1;
            2'd1:    tx_mode_to_byte_cnt = 2'd2;
            default: tx_mode_to_byte_cnt = 2'd3;
        endcase
    end
endfunction

// -------------------------------------------------------------------------
// CFG 寄存器 Shadow 机制
// -------------------------------------------------------------------------
reg [31:0] r_pending_cfg;
reg [31:0] r_active_cfg;

wire cfg_safe = tx_idle & tx_fifo_empty & rx_idle;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r_pending_cfg <= 32'h0000_0036;
    end else if (cfg_wr_req && !pslverr) begin
        r_pending_cfg <= pwdata;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r_active_cfg <= 32'h0000_0036;
    end else if (cfg_safe && (r_active_cfg != r_pending_cfg)) begin
        r_active_cfg <= r_pending_cfg;
    end
end

assign o_cfg_baud_div       = r_active_cfg[15:0];
assign o_cfg_parity_en_rx   = r_active_cfg[16];
assign o_cfg_parity_mode_rx = r_active_cfg[17];
assign o_cfg_stop_mode_rx   = r_active_cfg[18];
assign o_cfg_parity_en_tx   = r_active_cfg[19];
assign o_cfg_parity_mode_tx = r_active_cfg[20];
assign o_cfg_stop_mode_tx   = r_active_cfg[21];

wire [1:0] cfg_tx_burst = r_active_cfg[25:24];

wire [1:0] tx_byte_cnt = tx_mode_to_byte_cnt(cfg_tx_burst);

// -------------------------------------------------------------------------
// TX FSM
// -------------------------------------------------------------------------
localparam TX_IDLE = 1'b0;
localparam TX_BUSY = 1'b1;

reg        tx_state;
reg [1:0]  r_tx_remain;
reg [23:0] r_tx_data;
reg        r_tx_err;

wire tx_busy = (tx_state == TX_BUSY);

wire tx_accept = tx_wr_req &&
                 (tx_state == TX_IDLE) &&
                 !tx_fifo_full;

wire tx_err_now = tx_wr_req &&
                  ((tx_state != TX_IDLE) || tx_fifo_full);

wire tx_idle_fifo_we = tx_accept;
wire tx_busy_fifo_we = (tx_state == TX_BUSY) &&
                       !tx_fifo_full &&
                       (r_tx_remain != 2'd0);

assign o_tx_fifo_we = tx_idle_fifo_we | tx_busy_fifo_we;

assign o_tx_fifo_wdata = tx_idle_fifo_we ? pwdata[7:0] :
                                           r_tx_data[7:0];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_state    <= TX_IDLE;
        r_tx_remain <= 2'd0;
        r_tx_data   <= 24'd0;
        r_tx_err    <= 1'b0;
    end else begin
        if (status_rd_req) begin
            r_tx_err <= 1'b0;
        end else if (tx_err_now) begin
            r_tx_err <= 1'b1;
        end

        case (tx_state)
            TX_IDLE: begin
                r_tx_remain <= 2'd0;

                if (tx_accept) begin
                    r_tx_data <= {8'd0, pwdata[23:8]};

                    if (tx_byte_cnt > 2'd1) begin
                        r_tx_remain <= tx_byte_cnt - 2'd1;
                        tx_state    <= TX_BUSY;
                    end else begin
                        r_tx_remain <= 2'd0;
                        tx_state    <= TX_IDLE;
                    end
                end
            end

            TX_BUSY: begin
                if (!tx_fifo_full && (r_tx_remain != 2'd0)) begin
                    r_tx_data <= {8'd0, r_tx_data[23:8]};

                    if (r_tx_remain == 2'd1) begin
                        r_tx_remain <= 2'd0;
                        tx_state    <= TX_IDLE;
                    end else begin
                        r_tx_remain <= r_tx_remain - 2'd1;
                        tx_state    <= TX_BUSY;
                    end
                end
            end

            default: begin
                tx_state    <= TX_IDLE;
                r_tx_remain <= 2'd0;
            end
        endcase
    end
end

// -------------------------------------------------------------------------
// RX single-byte latch
// -------------------------------------------------------------------------
reg [7:0] r_rx_data;
reg       r_rx_done;
reg       r_rx_err;

wire rx_err_now = rx_rd_req && !r_rx_done;

assign o_rx_fifo_re = !r_rx_done && !rx_fifo_empty;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r_rx_data   <= 8'd0;
        r_rx_done   <= 1'b0;
        r_rx_err    <= 1'b0;
    end else begin
        if (status_rd_req) begin
            r_rx_err <= 1'b0;
        end else if (rx_err_now) begin
            r_rx_err <= 1'b1;
        end

        if (rx_rd_req) begin
            r_rx_done <= 1'b0;
            r_rx_data <= 8'd0;
        end else if (o_rx_fifo_re) begin
            r_rx_data <= rx_fifo_rdata;
            r_rx_done <= 1'b1;
        end
    end
end

// -------------------------------------------------------------------------
// IRQ
// -------------------------------------------------------------------------
reg rx_done_d;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_done_d <= 1'b0;
    end else begin
        rx_done_d <= r_rx_done;
    end
end

assign o_irq = r_rx_done & ~rx_done_d;

// -------------------------------------------------------------------------
// APB Error / Ready
// -------------------------------------------------------------------------
wire apb_addr_err = apb_access && !addr_valid;

wire apb_error = apb_addr_err |
                 tx_err_now   |
                 rx_err_now;

assign pready  = apb_access;
assign pslverr = apb_error;

// -------------------------------------------------------------------------
// APB Read Data
// -------------------------------------------------------------------------
reg [31:0] r_prdata;

assign prdata = r_prdata;

always @(*) begin
    case (reg_offset)
        ADDR_CFG: begin
            r_prdata = r_pending_cfg;
        end

        ADDR_TX: begin
            r_prdata = {8'd0, r_tx_data};
        end

        ADDR_RX: begin
            r_prdata = {24'd0, r_rx_data};
        end

        ADDR_STATUS: begin
            r_prdata = {
                21'd0,
                r_tx_err,
                rx_fifo_cnt,
                rx_fifo_empty,
                rx_fifo_full,
                tx_fifo_empty,
                tx_fifo_full,
                tx_busy
            };
        end

        default: begin
            r_prdata = 32'd0;
        end
    endcase
end

endmodule
