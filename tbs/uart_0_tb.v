`timescale 1ns/1ps

module uart_tb;

// =========================================================================
// Parameters
// =========================================================================
localparam integer CLK_PERIOD = 20;
localparam [15:0] BAUD_DIV   = 16'h01B2;
localparam [31:0] CFG_DATA   = {4'h0, 6'b010000, 6'b001001, BAUD_DIV};

localparam [31:0] ADDR_CFG = 32'h00000000;
localparam [31:0] ADDR_TX  = 32'h00000004;
localparam [31:0] ADDR_RX  = 32'h00000008;
localparam [31:0] ADDR_STA = 32'h0000000C;
localparam integer TX_COUNT = 256;

// =========================================================================
// Signals
// =========================================================================
reg          clk;
reg          rst_n;
reg          psel;
reg          penable;
reg          pwrite;
reg  [31:0]  paddr;
reg  [31:0]  pwdata;
wire [31:0]  prdata;
wire         pready;
wire         pslverr;
wire         tx_pin;
wire         irq;
reg[31:0]  cfg_rb;
reg  [31:0]  sta_rd;
reg  [31:0]  rx_rd;
integer      tx_cnt;
integer      i;
time write_start;
time         write_end;
real         write_eta_ns;
integer      wait_cycles;

reg[7:0]   tx_data;

reg[7:0]   rx_expect [0:TX_COUNT-1];
reg  [7:0]   rx_got[0:TX_COUNT-1];
integer      rx_err_cnt;
integer      irq_rx_cnt;
reg[31:0]  irq_rx_data;

reg isr_active;
reg          irq_held;
reg          cpu_irq_pending;

integer      batch_size;
integer      sent_in_batch;
integer      poll_cnt;
integer      wait_count;

wire [7:0]   r_val;
assign r_val = rx_rd[7:0];

integer      tx_cycles[0:TX_COUNT-1];
integer      tx_retries [0:TX_COUNT-1];
integer      cur_retries;
time         tx_frame_start;

reg last_apb_pslverr;
reg          apb_safe_done;

// ★ APB 总线互斥
reg          apb_bus_busy;

// ★ 用于主线程等待 ISR 完成的标志
reg          tx_wants_bus;

// =========================================================================
// Interrupt Manager
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_irq_pending <= 1'b0;
        irq_held<= 1'b0;end else begin
        if (irq && !isr_active && !cpu_irq_pending)
            cpu_irq_pending <= 1'b1;
        else if (irq && isr_active)
            irq_held <= 1'b1;

        if (!isr_active && irq_held && !cpu_irq_pending) begin
            cpu_irq_pending <= 1'b1;
            irq_held        <= 1'b0;
        end

        if (isr_active && cpu_irq_pending)
            cpu_irq_pending <= 1'b0;
    end
end

// =========================================================================
// DUT
// =========================================================================
uart u_uart (
    .clk(clk),
    .rst_n   (rst_n),
    .psel    (psel),
    .penable (penable),
    .pwrite  (pwrite),
    .paddr   (paddr),
    .pwdata  (pwdata),
    .prdata  (prdata),
    .pready  (pready),
    .pslverr (pslverr),
    .rx_pin  (tx_pin),
    .tx_pin  (tx_pin),
    .irq     (irq)
);

// =========================================================================
// Clock
// =========================================================================
initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

// =========================================================================
// APB Write - 保证事务间至少 4 周期空闲
// =========================================================================
task apb_write;
    input [31:0] addr;
    input [31:0] data;
    begin
        // 等待总线空闲
        while (apb_bus_busy) @(posedge clk);
        apb_bus_busy = 1'b1;

        write_start = $time;
        wait_cycles = 0;

        // SETUP phase
        @(posedge clk); #1;
        psel    = 1'b1;
        penable = 1'b0;
        pwrite  = 1'b1;
        paddr   = addr;
        pwdata  = data;

        // ACCESS phase
        @(posedge clk); #1;
        penable = 1'b1;

        @(posedge clk); #1;

        //等待 pready
        while (!pready) begin
            wait_cycles = wait_cycles + 1;
            @(posedge clk); #1;
        end

        last_apb_pslverr = pslverr;
        write_end    = $time;
        write_eta_ns = (write_end - write_start) * 1.0;

        // 释放总线
        psel    = 1'b0;
        penable = 1'b0;
        pwrite  = 1'b0;

        // ★ 4 个空闲周期
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);

        apb_bus_busy = 1'b0;
    end
endtask

// =========================================================================
// APB Read - 保证事务间至少 4 周期空闲
// =========================================================================
task apb_read;
    input  [31:0] addr;
    output [31:0] rdata;
    begin
        while (apb_bus_busy) @(posedge clk);
        apb_bus_busy = 1'b1;

        // SETUP phase
        @(posedge clk); #1;
        psel    = 1'b1;
        penable = 1'b0;
        pwrite  = 1'b0;
        paddr   = addr;
        pwdata  = 32'd0;

        // ACCESS phase
        @(posedge clk); #1;
        penable = 1'b1;

        @(posedge clk); #1;

        // 等待 pready
        while (!pready) begin
            @(posedge clk); #1;
        end

        last_apb_pslverr = pslverr;

        if (pslverr)
            rdata = 32'hDEAD_BEEF;
        else
            rdata = prdata;

        // 释放总线
        psel    = 1'b0;
        penable = 1'b0;

        // ★ 4 个空闲周期
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        @(posedge clk);

        apb_bus_busy = 1'b0;
    end
endtask

// =========================================================================
// APB Write Safe (带重试)
// =========================================================================
task apb_write_safe;
    input [31:0] addr;
    input [31:0] data;
    begin
        apb_safe_done = 0;
        cur_retries   = 0;

        while (!apb_safe_done) begin
            apb_write(addr, data);

            if (!last_apb_pslverr) begin
                apb_safe_done = 1;
            end else begin
                cur_retries = cur_retries + 1;
                repeat(100) @(posedge clk);
            end
        end
    end
endtask

// =========================================================================
// ISR Block - 不再被isr_active 阻塞发送
// =========================================================================
initial begin
    isr_active  = 1'b0;
    irq_held    = 1'b0;
    irq_rx_cnt  = 0;

    for (i = 0; i < TX_COUNT; i = i + 1) rx_got[i] = 8'hFF;

    @(posedge rst_n);
    repeat(20) @(posedge clk);

    forever begin
        // 等待中断挂起
        wait (cpu_irq_pending === 1'b1);
        @(posedge clk);

        isr_active = 1'b1;

        // 读RX 数据
        apb_read(ADDR_RX, rx_rd);
        rx_got[irq_rx_cnt] = rx_rd[7:0];
        irq_rx_data = rx_rd;

        $display("[%0t] ISR: RX[%0d] = 0x%02X%s", $time, irq_rx_cnt, irq_rx_data[7:0],
                 (last_apb_pslverr ? " [PSLVERR!]" : ""));
        irq_rx_cnt = irq_rx_cnt + 1;

        isr_active = 1'b0;

        // ★ ISR 处理完后不再加大延迟，尽快释放
        repeat(2) @(posedge clk);
    end
end

// =========================================================================
// Main Stimulus - 串行化：发一帧，等收完再发下一帧
// =========================================================================
initial begin
    psel             = 0;
    penable          = 0;
    pwrite           = 0;
    paddr            = 0;
    pwdata           = 0;
    tx_cnt           = 0;
    rst_n            = 0;
    rx_err_cnt       = 0;
    poll_cnt         = 0;
    cur_retries      = 0;
    last_apb_pslverr = 0;
    apb_safe_done    = 0;
    apb_bus_busy     = 0;
    tx_wants_bus     = 0;

    for (i = 0; i < TX_COUNT; i = i + 1) begin
        tx_cycles[i]  = 0;
        tx_retries[i] = 0;
        rx_expect[i]  = 8'h00;
    end

    repeat(10) @(posedge clk);
    #20rst_n = 1;

    $display("\n[%0t] ========== UART Loopback IRQ Test (0x00~0xFF) ==========", $time);
    repeat(5) @(posedge clk);

    // 写配置
    apb_write(ADDR_CFG, CFG_DATA);
    repeat(30) @(posedge clk);

    // 回读验证
    apb_read(ADDR_CFG, cfg_rb);
    if (cfg_rb == CFG_DATA)
        $display("[%0t] CFG verify OK: 0x%08X\n", $time, cfg_rb);
    else
        $display("[%0t] CFG verify FAIL: got 0x%08X, exp 0x%08X\n", $time, cfg_rb, CFG_DATA);

    //=====================逐帧发送 =====================
    for (tx_cnt = 0; tx_cnt < TX_COUNT; tx_cnt = tx_cnt + 1) begin

        tx_data = tx_cnt[7:0];
        rx_expect[tx_cnt] = tx_data;

        tx_frame_start = $time;

        // 发送
        apb_write_safe(ADDR_TX, {24'd0, tx_data});

        tx_cycles [tx_cnt] = ($time - tx_frame_start) / CLK_PERIOD;
        tx_retries[tx_cnt] = cur_retries;

        $display("[%0t] TX[%0d] = 0x%02X (retries=%0d)",
                 $time, tx_cnt, tx_data, cur_retries);

        // ★ 等待这一帧被ISR 接收完毕再发下一帧
        // 这样绝不会溢出 FIFO
        wait_count = 0;
        while (irq_rx_cnt <= tx_cnt && wait_count < 100000) begin
            @(posedge clk);
            wait_count = wait_count + 1;
        end

        if (wait_count >= 100000) begin
            $display("[%0t] ERROR: Timeout waiting for RX[%0d]", $time, tx_cnt);end

        // ★ 额外间隔确保状态稳定
        repeat(10) @(posedge clk);
    end

    // ===================== 最终等待 =====================
    $display("\n[%0t] All TX done, waiting for final RX...", $time);

    wait_count = 0;
    while (irq_rx_cnt < TX_COUNT && wait_count < 200000) begin
        repeat(100) @(posedge clk);
        wait_count = wait_count + 100;
    end

    if (irq_rx_cnt >= TX_COUNT)
        $display("[%0t] All RX data received", $time);
    else
        $display("[%0t] WARNING: RX timeout, received %0d/%0d", $time, irq_rx_cnt, TX_COUNT);

    repeat(1000) @(posedge clk);

    apb_read(ADDR_STA, sta_rd);
    $display("[%0t] Final UART Status: 0x%08X", $time, sta_rd);

    // ===================== 数据比对 =====================
    $display("\n================ TX/RX Data Comparison ================");
    $display(" No. | TX Expect | RX Got| Result");
    $display("-------------------------------------------------------");
    rx_err_cnt = 0;
    for (i = 0; i < TX_COUNT; i = i + 1) begin
        if (rx_expect[i] === rx_got[i])
            $display(" %3d |0x%02X   |  0x%02X   | PASS", i, rx_expect[i], rx_got[i]);
        else begin
            $display(" %3d |   0x%02X   |  0x%02X   | FAIL<<<", i, rx_expect[i], rx_got[i]);
            rx_err_cnt = rx_err_cnt + 1;
        end
    end

    // ===================== 统计表 =====================
    $display("\n============= TX Transmission Statistics ==============");
    $display(" No. |  TX Data  | Cycles | Retries |  Result");
    $display("-------------------------------------------------------");
    for (i = 0; i < TX_COUNT; i = i + 1) begin
        $display(" %3d |0x%02X    | %6d | %7d | %s",
                 i, rx_expect[i], tx_cycles[i], tx_retries[i],
                 (rx_expect[i] === rx_got[i]) ? "PASS" : "FAIL <<<");
    end

    $display("\n================== Final Report =======================");
    $display("Total TX Bytes: %d", TX_COUNT);
    $display("  Total RX Bytes   : %d", irq_rx_cnt);
    $display("  Error Count      : %d", rx_err_cnt);
    $display("  Test Result      : %s",(rx_err_cnt == 0 && irq_rx_cnt == TX_COUNT) ? "PASS" : "FAIL");
    $display("=======================================================\n");

    repeat(20) @(posedge clk);
    $finish;
end

// =========================================================================
// Timeout
// =========================================================================
initial begin
    #(CLK_PERIOD * 8000000);
    $display("\n[ERROR] Simulation timeout!");
    $finish;
end

// =========================================================================
// Waveform
// =========================================================================
initial begin
`ifdef DUMP_FSDB
    $fsdbDumpfile("uart_0.fsdb");
    $fsdbDumpvars(0, uart_tb);
    $fsdbDumpMDA();
`else
    $dumpfile("uart_tb.vcd");
    $dumpvars(0, uart_tb);
`endif
end

endmodule
