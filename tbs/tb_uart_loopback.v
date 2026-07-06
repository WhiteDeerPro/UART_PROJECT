`timescale 1ns / 1ps

module tb_uart_loopback;

reg clk;
reg rst_n;

initial clk = 0;
always #5 clk = ~clk;  // 100MHz

wire       tx_pin;
wire [7:0] rx_data_out;
wire       rx_valid;
wire       rx_err_frame;
wire       rx_err_parity;
wire       tx_fifo_empty;
wire       tx_fifo_full;
wire       rx_fifo_empty;
wire       rx_fifo_full;

uart_loopback_top u_dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .tx_pin        (tx_pin),
    .rx_data_out   (rx_data_out),
    .rx_valid      (rx_valid),
    .rx_err_frame  (rx_err_frame),
    .rx_err_parity (rx_err_parity),
    .tx_fifo_empty (tx_fifo_empty),
    .tx_fifo_full  (tx_fifo_full),
    .rx_fifo_empty (rx_fifo_empty),
    .rx_fifo_full  (rx_fifo_full)
);

integer i;

reg [7:0] expect_data [0:15];

initial begin
    rst_n = 1'b0;
    #200;
    rst_n = 1'b1;
    #20;

    for (i = 0; i < 16; i = i + 1) begin
        case (i % 4)
            0: begin u_dut.u_tx_fifo.mem[i] = 8'hAA; expect_data[i] = 8'hAA; end
            1: begin u_dut.u_tx_fifo.mem[i] = 8'h55; expect_data[i] = 8'h55; end
            2: begin u_dut.u_tx_fifo.mem[i] = 8'hA5; expect_data[i] = 8'hA5; end
            3: begin u_dut.u_tx_fifo.mem[i] = 8'h5A; expect_data[i] = 8'h5A; end
        endcase
    end

    force u_dut.u_tx_fifo.wr_ptr  = 4'd0;
    force u_dut.u_tx_fifo.rd_ptr  = 4'd0;
    force u_dut.u_tx_fifo.cnt     = 5'd16;
    force u_dut.u_tx_fifo.full_r  = 1'b1;
    force u_dut.u_tx_fifo.empty_r = 1'b0;

    repeat(4) @(posedge clk);

    release u_dut.u_tx_fifo.wr_ptr;
    release u_dut.u_tx_fifo.rd_ptr;
    release u_dut.u_tx_fifo.cnt;
    release u_dut.u_tx_fifo.full_r;
    release u_dut.u_tx_fifo.empty_r;

    $display("==============================================");
    $display("  UART Loopback Test Start");
    $display("  100MHz CLK, 115200 Baud, Odd Parity");
    $display("  TX FIFO: 16 bytes (AA/55/A5/5A pattern)");
    $display("==============================================");
end

integer rx_cnt;
integer err_cnt;

initial begin
    rx_cnt  = 0;
    err_cnt = 0;
end

always @(posedge clk) begin
    if (rx_valid) begin
        if (rx_cnt < 16) begin
            if (rx_data_out == expect_data[rx_cnt])
                $display("[%0t] RX[%0d] = 0x%02H OK", $time, rx_cnt, rx_data_out);
            else begin
                $display("[%0t] RX[%0d] = 0x%02H FAIL (expected 0x%02H)",
                         $time, rx_cnt, rx_data_out, expect_data[rx_cnt]);
                err_cnt = err_cnt + 1;
            end
        end else begin
            $display("[%0t] RX[%0d] = 0x%02H EXTRA BYTE!", $time, rx_cnt, rx_data_out);
            err_cnt = err_cnt + 1;
        end
        rx_cnt = rx_cnt + 1;
    end

    if (rx_err_frame) begin
        $display("[%0t] *** FRAME ERROR at byte %0d ***", $time, rx_cnt);
        err_cnt = err_cnt + 1;
    end

    if (rx_err_parity) begin
        $display("[%0t] *** PARITY ERROR at byte %0d ***", $time, rx_cnt);
        err_cnt = err_cnt + 1;
    end
end

initial begin
    // 16字节 × 11bit / 115200 ≈ 1.53ms，留3ms余量
    #3_000_000;

    $display("==============================================");
    $display("  Test Complete!");
    $display("  Total RX bytes: %0d / 16", rx_cnt);
    $display("  Total Errors:   %0d", err_cnt);
    if (rx_cnt == 16 && err_cnt == 0)
        $display("  *** ALL PASSED ***");
    else
        $display("  *** FAILED ***");
    $display("==============================================");
    $finish;
end

always @(posedge tx_fifo_empty)
    $display("[%0t] TX FIFO Empty — all data sent.", $time);

initial begin
    $dumpfile("uart_loopback.vcd");
    $dumpvars(0, tb_uart_loopback);
end

endmodule