module uart (
    // 系统接口
    input  wire        clk,
    input  wire        rst_n,

    // APB 总线接口
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // UART 引脚
    input  wire        rx_pin,
    output wire        tx_pin,

    // 中断输出
    output wire        irq
);

    // =====================================================================
    // 内部信号声明
    // =====================================================================

    // 波特率发生器
    wire        baud_tick;
    wire        baud_tick_16x;
    wire [15:0] cfg_baud_div;

    // RX 配置
    wire        cfg_parity_en_rx;
    wire        cfg_parity_mode_rx;
    wire        cfg_stop_mode_rx;

    // TX 配置
    wire        cfg_parity_en_tx;
    wire        cfg_parity_mode_tx;
    wire        cfg_stop_mode_tx;

    // TX FIFO 接口
    wire        tx_fifo_we;
    wire [7:0]  tx_fifo_wdata;
    wire        tx_fifo_full;
    wire        tx_fifo_empty;
    wire [7:0]  tx_fifo_rdata;
    wire        tx_fifo_re;

    // RX FIFO 接口
    wire        rx_fifo_we;
    wire [7:0]  rx_fifo_wdata;
    wire        rx_fifo_full;
    wire        rx_fifo_empty;
    wire [4:0]  rx_fifo_cnt;
    wire        rx_fifo_re;
    wire [7:0]  rx_fifo_rdata;

    // RX 模块输出
    wire [7:0]  rx_data;
    wire        rx_valid;

    // UART 空闲状态
    wire        tx_idle;
    wire        rx_idle;

    // =====================================================================
    // 1. 波特率发生器
    // =====================================================================
    uart_brg u_brg (
        .clk             (clk),
        .rst_n           (rst_n),
        .cfg_baud_div    (cfg_baud_div),
        .o_baud_tick     (baud_tick),
        .o_baud_16x_tick (baud_tick_16x)
    );

    // =====================================================================
    // 2. TX FIFO
    // =====================================================================
    sync_fifo #(
        .DATA_WIDTH (8),
        .ADDR_WIDTH (4),
        .FWFT_EN    (1)
    ) u_tx_fifo (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (tx_fifo_we),
        .wr_data  (tx_fifo_wdata),
        .full     (tx_fifo_full),
        .rd_en    (tx_fifo_re),
        .rd_data  (tx_fifo_rdata),
        .empty    (tx_fifo_empty),
        .data_cnt ()
    );

    // =====================================================================
    // 3. RX FIFO
    // =====================================================================
    sync_fifo #(
        .DATA_WIDTH (8),
        .ADDR_WIDTH (4),
        .FWFT_EN    (1)
    ) u_rx_fifo (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (rx_fifo_we),
        .wr_data  (rx_fifo_wdata),
        .full     (rx_fifo_full),
        .rd_en    (rx_fifo_re),
        .rd_data  (rx_fifo_rdata),
        .empty    (rx_fifo_empty),
        .data_cnt (rx_fifo_cnt)
    );

    // =====================================================================
    // 4. UART TX
    // =====================================================================
    uart_tx u_tx (
        .clk             (clk),
        .rst_n           (rst_n),
        .baud_tick       (baud_tick),
        .tx_data         (tx_fifo_rdata),
        .tx_fifo_empty   (tx_fifo_empty),
        .cfg_parity_en   (cfg_parity_en_tx),
        .cfg_parity_mode (cfg_parity_mode_tx),
        .cfg_stop_mode   (cfg_stop_mode_tx),
        .o_tx_read_en    (tx_fifo_re),
        .o_tx_pin        (tx_pin),
        .o_tx_idle       (tx_idle)
    );

    // =====================================================================
    // 5. UART RX
    // =====================================================================
    uart_rx u_rx (
        .clk             (clk),
        .rst_n           (rst_n),
        .baud_tick_16x   (baud_tick_16x),
        .rx_pin          (rx_pin),
        .cfg_parity_en   (cfg_parity_en_rx),
        .cfg_parity_mode (cfg_parity_mode_rx),
        .cfg_stop_mode   (cfg_stop_mode_rx),
        .o_rx_data       (rx_data),
        .o_rx_valid      (rx_valid),
        .o_rx_err_frame  (),
        .o_rx_err_parity (),
        .o_rx_idle       (rx_idle)
    );

    // RX FIFO 写入逻辑
    assign rx_fifo_we    = rx_valid && !rx_fifo_full;
    assign rx_fifo_wdata = rx_data;

    // =====================================================================
    // 6. 寄存器模块
    // =====================================================================
    uart_regs u_regs (
        .clk                  (clk),
        .rst_n                (rst_n),
        .psel                 (psel),
        .penable              (penable),
        .pwrite               (pwrite),
        .paddr                (paddr),
        .pwdata               (pwdata),
        .prdata               (prdata),
        .pready               (pready),
        .pslverr              (pslverr),

        .o_cfg_baud_div       (cfg_baud_div),
        .o_cfg_parity_en_rx   (cfg_parity_en_rx),
        .o_cfg_parity_mode_rx (cfg_parity_mode_rx),
        .o_cfg_stop_mode_rx   (cfg_stop_mode_rx),
        .o_cfg_parity_en_tx   (cfg_parity_en_tx),
        .o_cfg_parity_mode_tx (cfg_parity_mode_tx),
        .o_cfg_stop_mode_tx   (cfg_stop_mode_tx),

        .o_tx_fifo_we         (tx_fifo_we),
        .o_tx_fifo_wdata      (tx_fifo_wdata),
        .tx_fifo_full         (tx_fifo_full),
        .tx_fifo_empty        (tx_fifo_empty),

        .o_rx_fifo_re         (rx_fifo_re),
        .rx_fifo_rdata        (rx_fifo_rdata),
        .rx_fifo_empty        (rx_fifo_empty),
        .rx_fifo_full         (rx_fifo_full),
        .rx_fifo_cnt          (rx_fifo_cnt),

        .tx_idle              (tx_idle),
        .rx_idle              (rx_idle),
        .o_irq                (irq)
    );

endmodule