module uart_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       baud_tick_16x,
    input  wire       rx_pin,

    // 来自 uart_regs 的配置字段
    input  wire       cfg_parity_en,   // 1: 使能校验
    input  wire       cfg_parity_mode, // 0: 偶校验, 1: 奇校验
    input  wire       cfg_stop_mode,   // 0: 1停止位, 1: 2停止位

    output wire [7:0] o_rx_data,
    output wire       o_rx_valid,
    output wire       o_rx_err_frame,
    output wire       o_rx_err_parity,
    output wire       o_rx_idle
);

// -------------------------------------------------------------------------
// 输入双寄存器同步
// -------------------------------------------------------------------------
reg r_rx_sync1;
reg r_rx_sync2;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r_rx_sync1 <= 1'b1;
        r_rx_sync2 <= 1'b1;
    end else begin
        r_rx_sync1 <= rx_pin;
        r_rx_sync2 <= r_rx_sync1;
    end
end

// -------------------------------------------------------------------------
// 状态机定义
// -------------------------------------------------------------------------
localparam S_IDLE   = 3'b000;
localparam S_START  = 3'b001;
localparam S_DATA   = 3'b010;
localparam S_PARITY = 3'b011;
localparam S_STOP   = 3'b100;

reg [2:0] r_state;
reg [2:0] r_state_next;

// -------------------------------------------------------------------------
// 计数器
// -------------------------------------------------------------------------
reg [3:0] r_sample_cnt;
reg [2:0] r_bit_cnt;

wire sample_center = (r_sample_cnt == 4'd7)  && baud_tick_16x;
wire bit_done      = (r_sample_cnt == 4'd15) && baud_tick_16x;

// -------------------------------------------------------------------------
// 数据移位与校验
// -------------------------------------------------------------------------
reg [7:0] r_rx_shift;
reg       r_parity_bit;
reg       r_parity_calc;

// -------------------------------------------------------------------------
// 帧错误累积标志
// -------------------------------------------------------------------------
reg r_frame_error_flag;

// -------------------------------------------------------------------------
// 输出脉冲寄存器
// -------------------------------------------------------------------------
reg r_rx_valid;
reg r_rx_err_frame;
reg r_rx_err_parity;

// -------------------------------------------------------------------------
// 状态寄存器
// -------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        r_state <= S_IDLE;
    else
        r_state <= r_state_next;
end

// -------------------------------------------------------------------------
// 次态逻辑
// -------------------------------------------------------------------------
always @(*) begin
    r_state_next = r_state;

    case (r_state)
        S_IDLE: begin
            if (!r_rx_sync2)
                r_state_next = S_START;
        end

        S_START: begin
            if (sample_center && r_rx_sync2)
                r_state_next = S_IDLE;  // 虚假起始位
            else if (bit_done)
                r_state_next = S_DATA;
        end

        S_DATA: begin
            if (bit_done && (r_bit_cnt == 3'd7))
                r_state_next = cfg_parity_en ? S_PARITY : S_STOP;
        end

        S_PARITY: begin
            if (bit_done)
                r_state_next = S_STOP;
        end

        S_STOP: begin
            if (bit_done && (r_bit_cnt == {2'b00, cfg_stop_mode}))
                r_state_next = S_IDLE;
        end

        default: begin
            r_state_next = S_IDLE;
        end
    endcase
end

// -------------------------------------------------------------------------
// 数据采样与控制逻辑
// -------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r_sample_cnt       <= 4'd0;
        r_bit_cnt          <= 3'd0;
        r_rx_shift         <= 8'd0;
        r_parity_bit       <= 1'b0;
        r_parity_calc      <= 1'b0;
        r_frame_error_flag <= 1'b0;
        r_rx_valid         <= 1'b0;
        r_rx_err_frame     <= 1'b0;
        r_rx_err_parity    <= 1'b0;
    end else begin
        // 输出标志为单周期脉冲，默认拉低
        r_rx_valid      <= 1'b0;
        r_rx_err_frame  <= 1'b0;
        r_rx_err_parity <= 1'b0;

        if (r_state == S_IDLE) begin
            r_sample_cnt       <= 4'd0;
            r_bit_cnt          <= 3'd0;
            r_parity_calc      <= 1'b0;
            r_frame_error_flag <= 1'b0;

        end else if (baud_tick_16x) begin
            // -------------------------------------------------------------
            // 采样计数器
            // -------------------------------------------------------------
            if (bit_done || ((r_state == S_START) && sample_center && r_rx_sync2))
                r_sample_cnt <= 4'd0;
            else
                r_sample_cnt <= r_sample_cnt + 1'b1;

            // -------------------------------------------------------------
            // 位计数器
            // 进入 S_STOP 前清零，覆盖 DATA->STOP / PARITY->STOP
            // -------------------------------------------------------------
            if ((r_state_next == S_STOP) && (r_state != S_STOP)) begin
                r_bit_cnt <= 3'd0;
            end else if (bit_done) begin
                if ((r_state == S_DATA) || (r_state == S_STOP))
                    r_bit_cnt <= r_bit_cnt + 1'b1;
            end

            // -------------------------------------------------------------
            // 中心点采样（第 7 个 baud_tick_16x）
            // -------------------------------------------------------------
            if (sample_center) begin
                case (r_state)
                    S_DATA: begin
                        r_rx_shift    <= {r_rx_sync2, r_rx_shift[7:1]};
                        r_parity_calc <= r_parity_calc ^ r_rx_sync2;
                    end

                    S_PARITY: begin
                        r_parity_bit <= r_rx_sync2;
                    end

                    S_STOP: begin
                        if (!r_rx_sync2)
                            r_frame_error_flag <= 1'b1;
                    end

                    default: begin
                    end
                endcase
            end

            // -------------------------------------------------------------
            // 最后一个停止位结束时统一输出结果
            // -------------------------------------------------------------
            if (bit_done && (r_state == S_STOP) &&
                (r_bit_cnt == {2'b00, cfg_stop_mode})) begin

                if (r_frame_error_flag) begin
                    r_rx_err_frame <= 1'b1;
                end else if (cfg_parity_en &&
                             (r_parity_bit != (r_parity_calc ^ cfg_parity_mode))) begin
                    r_rx_err_parity <= 1'b1;
                end else begin
                    r_rx_valid <= 1'b1;
                end
            end
        end
    end
end

// -------------------------------------------------------------------------
// 输出
// -------------------------------------------------------------------------
assign o_rx_data       = r_rx_shift;
assign o_rx_valid      = r_rx_valid;
assign o_rx_err_frame  = r_rx_err_frame;
assign o_rx_err_parity = r_rx_err_parity;
assign o_rx_idle       = (r_state == S_IDLE);

endmodule