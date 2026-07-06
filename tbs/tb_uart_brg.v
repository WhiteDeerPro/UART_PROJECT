`timescale 1ns / 1ps

module tb_uart_brg;

// -------------------------
// 参数定义
// -------------------------
parameter CLK_FREQ    = 100_000_000;   // 系统时钟 100MHz
parameter BAUD_9600   = CLK_FREQ / 9600;     // 10417
parameter BAUD_19200  = CLK_FREQ / 19200;    // 5208
parameter BAUD_115200 = CLK_FREQ / 115200;   // 868

parameter CLK_PERIOD  = 10;   // 10ns = 100MHz

// -------------------------
// 信号声明
// -------------------------
reg         clk;
reg         rst_n;
reg  [15:0] i_cfg_baud_div;

wire        o_baud_tick;
wire        o_baud_16x_tick;

// -------------------------
// 统计计数
// -------------------------
integer cnt_16x_tick;
integer cnt_1x_tick;
real    t_16x_start;
real    t_1x_start;
real    period_16x;
real    period_1x;

// -------------------------
// DUT 例化
// -------------------------
uart_brg u_uart_brg (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_cfg_baud_div (i_cfg_baud_div),
    .o_baud_tick    (o_baud_tick),
    .o_baud_16x_tick(o_baud_16x_tick)
);

// -------------------------
// 时钟生成
// -------------------------
initial clk = 0;
always #(CLK_PERIOD / 2) clk = ~clk;

// -------------------------
// 主测试流程
// -------------------------
initial begin
    $display("==============================");
    $display("  uart_brg Testbench Start");
    $display("==============================");

    // 初始化
    rst_n          = 0;
    i_cfg_baud_div = 16'd0;
    cnt_16x_tick   = 0;
    cnt_1x_tick    = 0;

    // 复位
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ---------- 测试1：9600 baud ----------
    $display("\n[TEST 1] Baud = 9600, i_cfg_baud_div = %0d", BAUD_9600);
    i_cfg_baud_div = BAUD_9600;
    run_test(9600);

    // ---------- 测试2：19200 baud ----------
    $display("\n[TEST 2] Baud = 19200, i_cfg_baud_div = %0d", BAUD_19200);
    i_cfg_baud_div = BAUD_9600;   // 先保持旧值
    repeat (5) @(posedge clk);
    i_cfg_baud_div = BAUD_19200;
    run_test(19200);

    // ---------- 测试3：115200 baud ----------
    $display("\n[TEST 3] Baud = 115200, i_cfg_baud_div = %0d", BAUD_115200);
    i_cfg_baud_div = BAUD_115200;
    run_test(115200);

    // ---------- 测试4：复位后恢复 ----------
    $display("\n[TEST 4] Reset during operation");
    i_cfg_baud_div = BAUD_9600;
    repeat (100) @(posedge clk);
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);
    $display("  Reset released, counters should restart from 0");

    // 等待首个 16x tick 出现
    @(posedge o_baud_16x_tick);
    $display("  First o_baud_16x_tick after reset: OK");

    repeat (20) @(posedge clk);

    $display("\n==============================");
    $display("  All Tests Done");
    $display("==============================");
    $finish;
end

// -------------------------
// 测试任务：采样N个tick并计算实际频率
// -------------------------
task run_test;
    input integer expected_baud;
    integer i;
    real expected_period_16x;
    real expected_period_1x;
    real error_16x;
    real error_1x;
    begin
        cnt_16x_tick = 0;
        cnt_1x_tick  = 0;

        // 等待首个 16x tick 同步起点
        @(posedge o_baud_16x_tick);
        t_16x_start = $realtime;

        // 采样 32 个 16x tick
        repeat (32) @(posedge o_baud_16x_tick);
        period_16x = ($realtime - t_16x_start) / 32.0;

        // 等待首个 1x tick 同步起点
        @(posedge o_baud_tick);
        t_1x_start = $realtime;

        // 采样 4 个 1x tick
        repeat (4) @(posedge o_baud_tick);
        period_1x = ($realtime - t_1x_start) / 4.0;

        // 计算期望周期
        expected_period_16x = 1_000_000_000.0 / (expected_baud * 16.0);  // ns
        expected_period_1x  = 1_000_000_000.0 / expected_baud;           // ns

        // 误差计算
        error_16x = ((period_16x - expected_period_16x) / expected_period_16x) * 100.0;
        error_1x  = ((period_1x  - expected_period_1x)  / expected_period_1x)  * 100.0;

        // 打印结果
        $display("  --- o_baud_16x_tick ---");
        $display("  Expected period : %.2f ns", expected_period_16x);
        $display("  Measured period : %.2f ns", period_16x);
        $display("  Error           : %.3f %%", error_16x);

        $display("  --- o_baud_tick ---");
        $display("  Expected period : %.2f ns", expected_period_1x);
        $display("  Measured period : %.2f ns", period_1x);
        $display("  Error           : %.3f %%", error_1x);

        // 判断是否超限
        if (error_16x > 3.0 || error_16x < -3.0)
            $display("  [WARN] o_baud_16x_tick error exceeds 3%%");
        else
            $display("  [PASS] o_baud_16x_tick within tolerance");

        if (error_1x > 3.0 || error_1x < -3.0)
            $display("  [WARN] o_baud_tick error exceeds 3%%");
        else
            $display("  [PASS] o_baud_tick within tolerance");
    end
endtask

// -------------------------
// 波形转储
// -------------------------
initial begin
    $dumpfile("tb_uart_brg.vcd");
    $dumpvars(0, tb_uart_brg);
end

endmodule