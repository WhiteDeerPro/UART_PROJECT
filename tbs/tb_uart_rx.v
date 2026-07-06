`timescale 1ns/1ps

module tb_uart_rx;

parameter CLK_PERIOD = 20;
parameter BAUD_DIV   = 16'd434;
parameter BAUD_RATE  = 115200;

// 关键：与BRG实际计数对齐
// 16x_div = 434>>4 = 27个时钟/tick，16tick/bit
// BIT_TIME = 27 * 16 * 20 = 8640ns
parameter BIT_TIME   = 8640;

reg         clk;
reg         rst_n;
reg  [15:0] cfg_baud_div;
wire        baud_tick;
wire        baud_16x_tick;
reg         rx_pin;
wire [7:0]  rx_data;
wire        rx_valid;
wire        rx_err_frame;
wire        rx_err_parity;

integer pass_cnt;
integer fail_cnt;

// 脉冲捕获寄存器
reg        cap_got;
reg [7:0]  cap_data;
reg        cap_valid;
reg        cap_err_frame;
reg        cap_err_parity;

// =========================================================
// DUT
// =========================================================
uart_brg u_brg (
    .clk             (clk),
    .rst_n           (rst_n),
    .i_cfg_baud_div  (cfg_baud_div),
    .o_baud_tick     (baud_tick),
    .o_baud_16x_tick (baud_16x_tick)
);

uart_rx u_rx (
    .clk              (clk),
    .rst_n            (rst_n),
    .i_baud_tick_16x  (baud_16x_tick),
    .i_rx_pin         (rx_pin),
    .o_rx_data        (rx_data),
    .o_rx_valid       (rx_valid),
    .o_rx_err_frame   (rx_err_frame),
    .o_rx_err_parity  (rx_err_parity)
);

// =========================================================
// 时钟
// =========================================================
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// =========================================================
// 实时捕获单周期脉冲
// =========================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cap_got        <= 1'b0;
        cap_data       <= 8'h00;
        cap_valid      <= 1'b0;
        cap_err_frame  <= 1'b0;
        cap_err_parity <= 1'b0;
    end else if (rx_valid | rx_err_frame | rx_err_parity) begin
        cap_got        <= 1'b1;
        cap_data       <= rx_data;
        cap_valid      <= rx_valid;
        cap_err_frame  <= rx_err_frame;
        cap_err_parity <= rx_err_parity;
    end
end

// =========================================================
// 任务：清除捕获标志
// =========================================================
task clear_cap;
    begin
        @(posedge clk);
        cap_got        = 1'b0;
        cap_valid      = 1'b0;
        cap_err_frame  = 1'b0;
        cap_err_parity = 1'b0;
        cap_data       = 8'h00;
    end
endtask

// =========================================================
// 任务：等待捕获标志（轮询 cap_got）
// =========================================================
task wait_cap;
    integer timeout;
    begin
        timeout = 0;
        while (!cap_got) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 50000) begin
                $display("  [ERROR] wait_cap timeout!");
                disable wait_cap;
            end
        end
    end
endtask

// =========================================================
// 任务：发送 UART 字节
// =========================================================
task send_uart_byte;
    input [7:0] data;
    input       parity;
    input       stop_ok;
    integer     i;
    begin
        rx_pin = 1'b0;
        #(BIT_TIME);
        for (i = 0; i < 8; i = i + 1) begin
            rx_pin = data[i];
            #(BIT_TIME);
        end
        rx_pin = parity;
        #(BIT_TIME);
        rx_pin = stop_ok ? 1'b1 : 1'b0;
        #(BIT_TIME);
        rx_pin = 1'b1;
        #(BIT_TIME);
    end
endtask

// =========================================================
// 主流程
// =========================================================
initial begin
    clk          = 0;
    rst_n        = 0;
    rx_pin       = 1'b1;
    cfg_baud_div = BAUD_DIV;
    pass_cnt     = 0;
    fail_cnt     = 0;
    cap_got      = 0;
    cap_data     = 0;
    cap_valid    = 0;
    cap_err_frame  = 0;
    cap_err_parity = 0;

    repeat(20) @(posedge clk);
    rst_n = 1'b1;
    repeat(10) @(posedge clk);

    $display("============================================");
    $display("   UART RX Testbench Start");
    $display("   BIT_TIME=%0dns  BAUD_DIV=%0d", BIT_TIME, BAUD_DIV);
    $display("============================================");

    // TC1
    $display("\n[TC1] Normal RX: 0x55, parity OK");
    clear_cap;
    send_uart_byte(8'h55, ^8'h55, 1'b1);
    wait_cap;
    if (cap_valid && cap_data==8'h55 && !cap_err_frame && !cap_err_parity) begin
        $display("  [PASS] data=0x%02X", cap_data);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  [FAIL] data=0x%02X valid=%b err_f=%b err_p=%b",
                  cap_data, cap_valid, cap_err_frame, cap_err_parity);
        fail_cnt = fail_cnt + 1;
    end
    #(BIT_TIME * 3);

    // TC2
    $display("\n[TC2] Normal RX: 0xA5, parity OK");
    clear_cap;
    send_uart_byte(8'hA5, ^8'hA5, 1'b1);
    wait_cap;
    if (cap_valid && cap_data==8'hA5 && !cap_err_frame && !cap_err_parity) begin
        $display("  [PASS] data=0x%02X", cap_data);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  [FAIL] data=0x%02X valid=%b err_f=%b err_p=%b",
                  cap_data, cap_valid, cap_err_frame, cap_err_parity);
        fail_cnt = fail_cnt + 1;
    end
    #(BIT_TIME * 3);

    // TC3
    $display("\n[TC3] Parity Error: 0x33, wrong parity");
    clear_cap;
    send_uart_byte(8'h33, ~(^8'h33), 1'b1);
    wait_cap;
    if (cap_valid && cap_err_parity && !cap_err_frame) begin
        $display("  [PASS] Parity error detected, data=0x%02X", cap_data);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  [FAIL] valid=%b err_f=%b err_p=%b",
                  cap_valid, cap_err_frame, cap_err_parity);
        fail_cnt = fail_cnt + 1;
    end
    #(BIT_TIME * 3);

    // TC4
    $display("\n[TC4] Frame Error: stop=0");
    clear_cap;
    send_uart_byte(8'hFF, ^8'hFF, 1'b0);
    wait_cap;
    if (!cap_valid && cap_err_frame && !cap_err_parity) begin
        $display("  [PASS] Frame error detected");
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  [FAIL] valid=%b err_f=%b err_p=%b",
                  cap_valid, cap_err_frame, cap_err_parity);
        fail_cnt = fail_cnt + 1;
    end
    #(BIT_TIME * 5);

    // TC5
    $display("\n[TC5] Noise Glitch (1/4 bit)");
    clear_cap;
    rx_pin = 1'b0;
    #(BIT_TIME / 4);
    rx_pin = 1'b1;
    #(BIT_TIME * 8);
    if (!cap_got) begin
        $display("  [PASS] Glitch filtered");
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  [FAIL] Spurious: valid=%b err_f=%b err_p=%b",
                  cap_valid, cap_err_frame, cap_err_parity);
        fail_cnt = fail_cnt + 1;
    end
    #(BIT_TIME * 2);

    // TC6
    $display("\n[TC6] Continuous: 0x12, 0x34, 0x56");

    clear_cap;
    send_uart_byte(8'h12, ^8'h12, 1'b1);
    wait_cap;
    if (cap_valid && cap_data==8'h12 && !cap_err_frame && !cap_err_parity) begin
        $display("  [PASS] [0] 0x%02X", cap_data);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  [FAIL] [0] got=0x%02X valid=%b", cap_data, cap_valid);
        fail_cnt = fail_cnt + 1;
    end
    #(BIT_TIME * 2);

    clear_cap;
    send_uart_byte(8'h34, ^8'h34, 1'b1);
    wait_cap;
    if (cap_valid && cap_data==8'h34 && !cap_err_frame && !cap_err_parity) begin
        $display("  [PASS] [1] 0x%02X", cap_data);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  [FAIL] [1] got=0x%02X valid=%b", cap_data, cap_valid);
        fail_cnt = fail_cnt + 1;
    end
    #(BIT_TIME * 2);

    clear_cap;
    send_uart_byte(8'h56, ^8'h56, 1'b1);
    wait_cap;
    if (cap_valid && cap_data==8'h56 && !cap_err_frame && !cap_err_parity) begin
        $display("  [PASS] [2] 0x%02X", cap_data);
        pass_cnt = pass_cnt + 1;
    end else begin
        $display("  [FAIL] [2] got=0x%02X valid=%b", cap_data, cap_valid);
        fail_cnt = fail_cnt + 1;
    end
    #(BIT_TIME * 2);

    // 汇总
    $display("\n============================================");
    $display("   PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
    $display("============================================");
    if (fail_cnt == 0)
        $display("   >>> ALL TESTS PASSED <<<");
    else
        $display("   >>> %0d TEST(S) FAILED <<<", fail_cnt);

    $finish;
end

initial begin
    $dumpfile("uart_rx_tb.vcd");
    $dumpvars(0, tb_uart_rx);
end

initial begin
    #(BIT_TIME * 500);
    $display("[TIMEOUT]");
    $finish;
end

endmodule