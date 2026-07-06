`timescale 1ns/1ps

module uart_tb;

localparam CLK_PERIOD  = 20;
localparam TOTAL_BYTES = 256;

// 地址映射
localparam [31:0] ADDR_CFG = 32'h0000_0000;
localparam [31:0] ADDR_TX  = 32'h0000_0004;
localparam [31:0] ADDR_RX  = 32'h0000_0008;
localparam [31:0] ADDR_STA = 32'h0000_000C;

// 配置：单字节 TX / 单字节 RX / 无校验 / 1停止位
localparam [15:0] BAUD_DIV = 16'h01B2;
localparam [31:0] CFG_DATA = {6'd0, 2'd0, 2'd0, 6'd0, BAUD_DIV};

// 时钟复位
reg clk;
reg rst_n;

// APB
reg         psel;
reg         penable;
reg         pwrite;
reg  [31:0] paddr;
reg  [31:0] pwdata;
wire [31:0] prdata;
wire        pready;
wire        pslverr;

// UART
wire tx_pin;
wire rx_pin;
wire irq;

assign rx_pin = tx_pin; // 回环

uart dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .psel    (psel),
    .penable (penable),
    .pwrite  (pwrite),
    .paddr   (paddr),
    .pwdata  (pwdata),
    .prdata  (prdata),
    .pready  (pready),
    .pslverr (pslverr),
    .rx_pin  (rx_pin),
    .tx_pin  (tx_pin),
    .irq     (irq)
);

// 时钟
initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD/2) clk = ~clk;
end

// ------------------------------
// 全局变量
// ------------------------------
reg apb_busy;
reg [31:0] apb_rdata;

reg [7:0] rx_buf [0:TOTAL_BYTES-1];

integer rx_cnt;
integer tx_retry_cnt;
integer tx_fail_cnt;
integer tx_ok_cnt;
integer rx_irq_cnt;
integer rx_read_err_cnt;
integer i;

// task临时变量
reg apb_err;
reg [31:0] isr_data;
reg isr_err;
integer err_cnt;
integer shown_err_cnt;

// ------------------------------
// APB 基础任务
// ------------------------------
task apb_acquire;
begin
    while (apb_busy)
        @(posedge clk);
    apb_busy = 1'b1;
end
endtask

task apb_release;
begin
    psel     <= 1'b0;
    penable  <= 1'b0;
    pwrite   <= 1'b0;
    paddr    <= 32'd0;
    pwdata   <= 32'd0;
    apb_busy  = 1'b0;
end
endtask

task apb_write_once;
    input  [31:0] addr;
    input  [31:0] data;
    output        err;
begin
    apb_acquire;

    @(posedge clk);
    psel    <= 1'b1;
    penable <= 1'b0;
    pwrite  <= 1'b1;
    paddr   <= addr;
    pwdata  <= data;

    @(posedge clk);
    penable <= 1'b1;

    @(posedge clk);
    err = pslverr;

    apb_release;
end
endtask

task apb_read_once;
    input  [31:0] addr;
    output [31:0] data;
    output        err;
begin
    apb_acquire;

    @(posedge clk);
    psel    <= 1'b1;
    penable <= 1'b0;
    pwrite  <= 1'b0;
    paddr   <= addr;
    pwdata  <= 32'd0;

    @(posedge clk);
    penable <= 1'b1;

    @(posedge clk);
    data = prdata;
    err  = pslverr;

    apb_release;
end
endtask

// ------------------------------
// TX发送：失败则1024周期后重试
// ------------------------------
task send_bytes_by_polling;
    integer idx;
begin
    $display("[%0t] Start sending %0d bytes by polling...", $time, TOTAL_BYTES);

    for (idx = 0; idx < TOTAL_BYTES; idx = idx + 1) begin
        apb_err = 1'b1;
        while (apb_err) begin
            apb_write_once(ADDR_TX, {24'd0, idx[7:0]}, apb_err);

            if (apb_err) begin
                tx_fail_cnt  = tx_fail_cnt + 1;
                tx_retry_cnt = tx_retry_cnt + 1;
                repeat (1024) @(posedge clk);
            end
            else begin
                tx_ok_cnt = tx_ok_cnt + 1;
            end
        end
    end
end
endtask

// ------------------------------
// 等待全部接收完成
// ------------------------------
task wait_all_rx_done;
begin
    while (rx_cnt < TOTAL_BYTES)
        @(posedge clk);
end
endtask

// ------------------------------
// 校验数据
// 仅打印前16个错误
// ------------------------------
task check_rx_result;
    integer k;
begin
    err_cnt = 0;
    shown_err_cnt = 0;

    for (k = 0; k < TOTAL_BYTES; k = k + 1) begin
        if (rx_buf[k] !== k[7:0]) begin
            err_cnt = err_cnt + 1;
            if (shown_err_cnt < 16) begin
                $display("CHECK ERR: idx=%0d expect=0x%02X got=0x%02X",
                         k, k[7:0], rx_buf[k]);
                shown_err_cnt = shown_err_cnt + 1;
            end
        end
    end

    $display("");
    $display("+-------------------+------------------+");
    $display("| Item              | Value            |");
    $display("+-------------------+------------------+");
    $display("| TOTAL_BYTES       | %0d", TOTAL_BYTES);
    $display("| TX_OK_CNT         | %0d", tx_ok_cnt);
    $display("| TX_FAIL_CNT       | %0d", tx_fail_cnt);
    $display("| TX_RETRY_CNT      | %0d", tx_retry_cnt);
    $display("| RX_IRQ_CNT        | %0d", rx_irq_cnt);
    $display("| RX_READ_ERR_CNT   | %0d", rx_read_err_cnt);
    $display("| RX_CNT            | %0d", rx_cnt);
    $display("| CHECK_ERR_CNT     | %0d", err_cnt);
    $display("+-------------------+------------------+");

    if (err_cnt == 0)
        $display("| RESULT            | PASS             |");
    else
        $display("| RESULT            | FAIL             |");

    $display("+-------------------+------------------+");
    $display("");
end
endtask

// ------------------------------
// 中断服务进程
// irq 来了后读 RX
// 减少打印：每32个字节打印一次进度
// ------------------------------
initial begin
    forever begin
        @(posedge irq);
        rx_irq_cnt = rx_irq_cnt + 1;

        apb_read_once(ADDR_RX, isr_data, isr_err);

        if (isr_err) begin
            rx_read_err_cnt = rx_read_err_cnt + 1;
        end
        else begin
            if (rx_cnt < TOTAL_BYTES) begin
                rx_buf[rx_cnt] = isr_data[7:0];
                rx_cnt = rx_cnt + 1;

                if ((rx_cnt % 32) == 0)
                    $display("[%0t] RX progress: %0d / %0d",
                             $time, rx_cnt, TOTAL_BYTES);
            end
        end
    end
end

// ------------------------------
// 主测试流程
// ------------------------------
initial begin
    psel      = 1'b0;
    penable   = 1'b0;
    pwrite    = 1'b0;
    paddr     = 32'd0;
    pwdata    = 32'd0;
    rst_n     = 1'b0;
    apb_busy  = 1'b0;
    apb_rdata = 32'd0;

    rx_cnt          = 0;
    tx_retry_cnt    = 0;
    tx_fail_cnt     = 0;
    tx_ok_cnt       = 0;
    rx_irq_cnt      = 0;
    rx_read_err_cnt = 0;
    apb_err         = 1'b0;
    isr_data        = 32'd0;
    isr_err         = 1'b0;
    err_cnt         = 0;
    shown_err_cnt   = 0;

    for (i = 0; i < TOTAL_BYTES; i = i + 1)
        rx_buf[i] = 8'h00;

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    repeat (20) @(posedge clk);

    // 配置 UART
    apb_write_once(ADDR_CFG, CFG_DATA, apb_err);
    if (apb_err) begin
        $display("[%0t] CFG write failed!", $time);
        $finish;
    end
    else begin
        $display("[%0t] CFG write ok: 0x%08X", $time, CFG_DATA);
    end

    repeat (20) @(posedge clk);

    // 发送256字节
    send_bytes_by_polling();

    // 等待全部接收完成
    wait_all_rx_done();

    // 再等一会
    repeat (100) @(posedge clk);

    // 校验
    check_rx_result();

    $finish;
end

// ------------------------------
// 超时保护
// ------------------------------
initial begin
    #(CLK_PERIOD * 4000000);
    $display("[ERROR] Simulation timeout!");
    $finish;
end

// ------------------------------
// 波形
// ------------------------------
initial begin
`ifdef DUMP_FSDB
    $fsdbDumpfile("uart_1.fsdb");
    $fsdbDumpvars(0, uart_tb);
    $fsdbDumpMDA();
`else
    $dumpfile("uart_tb_256_poll_irq.vcd");
    $dumpvars(0, uart_tb);
`endif
end

endmodule
