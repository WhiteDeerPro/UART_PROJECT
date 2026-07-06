module uart_tx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       baud_tick,       // 1x 波特时钟
    input  wire [7:0] tx_data,         // FIFO 输出数据
    input  wire       tx_fifo_empty,   // FIFO 空标志

    // 来自 uart_regs 的配置字段
    input  wire       cfg_parity_en,   // 1: 使能校验
    input  wire       cfg_parity_mode, // 0: 偶校验, 1: 奇校验
    input  wire       cfg_stop_mode,   // 0: 1停止位, 1: 2停止位

    output wire       o_tx_read_en,    // 从 FIFO 取数使能
    output reg        o_tx_pin,        // 串行输出脚
    output wire       o_tx_idle
);

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
// 计数器与移位寄存器
// -------------------------------------------------------------------------
reg [2:0] r_bit_cnt;
reg [7:0] r_tx_shift;
reg       r_parity_bit;

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
            if (!tx_fifo_empty && baud_tick)
                r_state_next = S_START;
        end

        S_START: begin
            if (baud_tick)
                r_state_next = S_DATA;
        end

        S_DATA: begin
            if (baud_tick && (r_bit_cnt == 3'd7))
                r_state_next = cfg_parity_en ? S_PARITY : S_STOP;
        end

        S_PARITY: begin
            if (baud_tick)
                r_state_next = S_STOP;
        end

        S_STOP: begin
            if (baud_tick && (r_bit_cnt == {2'b00, cfg_stop_mode}))
                r_state_next = S_IDLE;
        end

        default: begin
            r_state_next = S_IDLE;
        end
    endcase
end

// -------------------------------------------------------------------------
// 发送控制逻辑
// -------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r_tx_shift   <= 8'd0;
        r_parity_bit <= 1'b0;
        r_bit_cnt    <= 3'd0;
        o_tx_pin     <= 1'b1;
    end else begin
        case (r_state)
            S_IDLE: begin
                o_tx_pin  <= 1'b1;
                r_bit_cnt <= 3'd0;

                if (!tx_fifo_empty) begin
                    r_tx_shift   <= tx_data;
                    r_parity_bit <= cfg_parity_mode ? (~^tx_data) : (^tx_data);
                end
            end

            S_START: begin
                if (baud_tick)
                    o_tx_pin <= 1'b0;
            end

            S_DATA: begin
                if (baud_tick) begin
                    o_tx_pin   <= r_tx_shift[0];
                    r_tx_shift <= {1'b0, r_tx_shift[7:1]};

                    if (r_bit_cnt == 3'd7)
                        r_bit_cnt <= 3'd0;
                    else
                        r_bit_cnt <= r_bit_cnt + 3'd1;
                end
            end

            S_PARITY: begin
                if (baud_tick) begin
                    o_tx_pin  <= r_parity_bit;
                    r_bit_cnt <= 3'd0;
                end
            end

            S_STOP: begin
                if (baud_tick) begin
                    o_tx_pin  <= 1'b1;
                    r_bit_cnt <= r_bit_cnt + 3'd1;
                end
            end

            default: begin
                o_tx_pin  <= 1'b1;
                r_bit_cnt <= 3'd0;
            end
        endcase
    end
end

// -------------------------------------------------------------------------
// FIFO 读使能：空闲态检测到可发数据后，拉高单周期脉冲
// -------------------------------------------------------------------------
assign o_tx_read_en = (r_state == S_IDLE) && (r_state_next == S_START);
assign o_tx_idle    = (r_state == S_IDLE);

endmodule