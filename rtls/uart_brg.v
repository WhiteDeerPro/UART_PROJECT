module uart_brg (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] cfg_baud_div,
    output wire        o_baud_tick,
    output wire        o_baud_16x_tick
);

    // ---------------------------------------------------------------------
    // 16x 波特时钟分频值
    // cfg_baud_div 表示 1x 波特周期对应的系统时钟数
    // 此处右移 4 位，用于生成 16x 过采样时钟
    // ---------------------------------------------------------------------
    wire [15:0] baud_div_16x = cfg_baud_div >> 4;

    // ---------------------------------------------------------------------
    // 16x 分频计数器
    // ---------------------------------------------------------------------
    reg [11:0] r_baud_16x_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            r_baud_16x_cnt <= 12'd0;
        else if (r_baud_16x_cnt >= (baud_div_16x - 1'b1))
            r_baud_16x_cnt <= 12'd0;
        else
            r_baud_16x_cnt <= r_baud_16x_cnt + 1'b1;
    end

    // ---------------------------------------------------------------------
    // 1x 波特时钟计数器
    // 每收到 16 个 16x tick，产生一个 1x tick
    // ---------------------------------------------------------------------
    reg [3:0] r_baud_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            r_baud_cnt <= 4'd0;
        else if (o_baud_16x_tick)
            r_baud_cnt <= r_baud_cnt + 1'b1;
    end

    // ---------------------------------------------------------------------
    // 输出脉冲
    // ---------------------------------------------------------------------
    assign o_baud_16x_tick = (r_baud_16x_cnt == (baud_div_16x - 1'b1));
    assign o_baud_tick     = o_baud_16x_tick && (r_baud_cnt == 4'hF);

endmodule