# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

"""

Expected top ports:
    clk, rst_n, ena, ui_in[7:0], uio_in[7:0], uo_out[7:0]

Pin map:
    ui_in[7:0]  : host->ASIC DTR data
    uio_in[0]   : host VALID
    uo_out[0]   : ASIC READY
    uo_out[1]   : DSP busy (live)
    uo_out[2]   : config pending (live)
    uo_out[3]   : coefficient commit pending (live)
    uo_out[4]   : protocol error (sticky)
    uo_out[5]   : coefficients updated (sticky)
    uo_out[6]   : config updated (sticky)
    uo_out[7]   : 1-bit sigma-delta audio output

Architectural contract:
    CONTROL: header only, ID=[7:6]
    CONFIG:  header only, NUM_TAPS=[15:12], OUT_SHIFT=[11:8], SAT=[7]
    COEFF:   header with WE=[13:6], exactly 8 signed 16-bit payloads
    DATA:    header with LEN=1..15, each payload is signed 16-bit PCM
    LEN=[5:2] counts payload flits; TYPE=[1:0].

ASSUMPTIONS THAT MUST BE FROZEN BEFORE RUNNING ALL FIR TESTS:
    - Coefficients and input PCM are signed two's-complement 16-bit.
    - ACC is the exact sum of products and OUT_SHIFT means arithmetic >>.
    - SAT_EN=1 clamps to signed 16-bit after shifting.
    - NUM_TAPS=0 bypasses multiplication and output shift.
    - RESET_FILTER clears FIR history only.
    - output TX is the accumulator/carry PDM implementation discussed.
    - The FIR finishes and exposes a new PCM sample within SETTLE_CYCLES;
      this can be increased for a slower microarchitecture.

If rounding/truncation/saturation differs from these assumptions, update
fir_result() accordingly instead of weakening the checks.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer

CLK_PERIOD_NS = 40   # 25 MHz; host provides this clock
MAX_READY_RETRIES = 10000
MAX_STATUS_WAIT = 2000
SETTLE_CYCLES = 512
PDM_WINDOW = 4096
PDM_TOLERANCE_BITS = 2

T_CONTROL, T_COEFF, T_CONFIG, T_DATA = range(4)
CTRL_COMMIT, CTRL_RESET_FILTER, CTRL_CLEAR_STATUS = 1, 2, 3

READY = 0
BUSY = 1
CONFIG_PENDING = 2
COEFF_PENDING = 3
PROTOCOL_ERROR = 4
COEFF_UPDATED = 5
CONFIG_UPDATED = 6
AUDIO = 7


def bit(dut, n):
    return (int(dut.uo_out.value) >> n) & 1

def to_s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x

def header(typ, length, meta=0):
    assert 0 <= typ < 4 and 0 <= length <= 15 and 0 <= meta < 1024
    return (meta << 6) | (length << 2) | typ

def config_packet(taps, shift=15, saturate=True):
    assert 0 <= taps <= 8 and 0 <= shift <= 15
    # [15:12]=taps, [11:8]=shift, [7]=sat, [6]=reserved
    return [(taps << 12) | (shift << 8) | (int(bool(saturate)) << 7)
            | T_CONFIG]

def control_packet(command):
    assert command in (CTRL_COMMIT, CTRL_RESET_FILTER, CTRL_CLEAR_STATUS)
    return [header(T_CONTROL, 0, command)]

def coeff_packet(coeffs, mask=0xFF):
    assert len(coeffs) == 8 and 0 <= mask <= 255
    return [header(T_COEFF, 8, mask)] + [x & 0xFFFF for x in coeffs]

def data_packet(samples):
    assert 1 <= len(samples) <= 15
    return [header(T_DATA, len(samples))] + [x & 0xFFFF for x in samples]

def fir_result(samples, coeffs, taps, shift, saturate=True):
    """Golden reference for output corresponding to the FINAL sample in samples.

    The first sample in `samples` is assumed to start with zeroed FIR history.
    For ongoing history, pass ALL samples from last RESET_FILTER.
    """
    if taps == 0:
        return to_s16(samples[-1])
    accum = 0
    for i in range(taps):
        if i >= len(samples):
            break
        accum += to_s16(samples[-1-i]) * to_s16(coeffs[i])

    shifted = accum >> shift
    if saturate:
        return max(-32768, min(32767, shifted))
    return to_s16(shifted)

async def initialize(dut):
    dut.clk.value = 0
    dut.rst_n.value = 0
    if hasattr(dut, 'ena'):
        dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit='ns').start())
    await ClockCycles(dut.clk, 8)
    await FallingEdge(dut.clk)
    await Timer(1, unit='ns')
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 8)
    await Timer(1, unit='ns')


async def send_flits(dut, words, name='packet'):
    """Complete real DTR transfers on the PHYSICAL pins.

    The high byte is placed before each posedge, and the low byte before
    the following negedge. Acceptance happens ONLY on the posedge.
    If READY is low, retry the same full 16-bit word next cycle.

    Does not inspect internal RX/parser or DSP signals.
    """
    stalls = 0
    await FallingEdge(dut.clk)
    await Timer(1, unit='ns')

    for index, word in enumerate(words):
        word &= 0xFFFF
        hi, lo = (word >> 8), (word & 0xFF)
        for _ in range(MAX_READY_RETRIES):
            dut.ui_in.value = hi
            dut.uio_in.value = 1  # physical uio_in[0] = host VALID
            await Timer(1, unit='ns')
            ready_for_edge = bit(dut, READY)

            await RisingEdge(dut.clk)  # capture high if READY && VALID
            await Timer(1, unit='ns')
            dut.ui_in.value = lo
            await FallingEdge(dut.clk)  # low captured for accepted flit
            await Timer(1, unit='ns')
            if ready_for_edge:
                break
            stalls += 1
        else:
            raise AssertionError(
                f'{name}: READY timeout on flit {index} (0x{word:04X}); '
                f'uo_out=0x{int(dut.uo_out.value):02X}'
            )

    dut.uio_in.value = 0
    dut.ui_in.value = 0
    dut._log.info('%s: sent %d flits, %d stalled clocks', name, len(words), stalls)
    return stalls

async def expect_pin(dut, n, expected=1, timeout=MAX_STATUS_WAIT):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        await Timer(1, unit='ns')
        if bit(dut, n) == expected:
            return
    raise AssertionError(
        f'uo_out[{n}] did not become {expected} in {timeout} clocks; '
        f'last uo_out=0x{int(dut.uo_out.value):02X}'
    )

async def wait_processing(dut):
    # No top-level output-sample VALID pin exists. Use a generous bounded
    # completion window that must exceed the FIR's worst-case latency.
    await ClockCycles(dut.clk, SETTLE_CYCLES)
    await Timer(1, unit='ns')
    assert bit(dut, BUSY) == 0, 'FIR still busy after SETTLE_CYCLES'

async def measure_pdm_ones(dut, n=PDM_WINDOW):
    ones = 0
    for _ in range(n):
        await RisingEdge(dut.clk)
        await Timer(1, unit='ns')
        value = bit(dut, AUDIO)
        ones += value
    return ones


async def check_audio(dut, expected_pcm, note=''):
    """End-to-end audio check at top-level Pmod output pin.

    We cannot inspect the FIR result register, so we measure the output
    sigma-delta pulse density and compare against the golden PCM result.
    """
    await wait_processing(dut)
    ones = await measure_pdm_ones(dut)
    level = (expected_pcm & 0xFFFF) ^ 0x8000
    target = PDM_WINDOW * level / 65536.0
    err = abs(ones - target)
    dut._log.info('%s expected PCM=%d, ones=%d/%d, target=%.3f',
                  note, expected_pcm, ones, PDM_WINDOW, target)
    assert err <= PDM_TOLERANCE_BITS, (
        f'{note}: PDM density mismatch, expected PCM={expected_pcm}, '
        f'got ones={ones} (expected {target:.2f}, error {err:.2f})'
    )
    assert bit(dut, PROTOCOL_ERROR) == 0, f'{note}: unexpected protocol error'


async def write_coeffs_and_commit(dut, coeffs):
    await send_flits(dut, coeff_packet(coeffs), 'COEFF_WRITE full bank')
    await send_flits(dut, control_packet(CTRL_COMMIT), 'COMMIT_COEFF')
    await expect_pin(dut, COEFF_UPDATED, 1)
    await expect_pin(dut, COEFF_PENDING, 0)


@cocotb.test()
async def test_top_bypass_full_path(dut):
    """Physical DTR -> parser -> config -> bypass FIR -> PDM -> output pin."""
    await initialize(dut)
    await send_flits(dut, config_packet(0, 15, True), 'CONFIG bypass')
    await expect_pin(dut, CONFIG_UPDATED, 1)

    for sample in (-32768, -16384, 0, 16384, 32767, -5678, 9876):
        await send_flits(dut, data_packet([sample]), f'PCM={sample}')
        await check_audio(dut, sample, f'bypass PCM={sample}')


@cocotb.test()
async def test_top_three_tap_signed_fir(dut):
    """Real signed FIR arithmetic AND sample history, observed through PDM.

    h[0]=1/2, h[1]=1/4, h[2]=1/4 (Q1.15).
    Includes positive and negative samples; exact expected results.
    """
    await initialize(dut)
    coeffs = [0x4000, 0x2000, 0x2000, 0, 0, 0, 0, 0]
    await write_coeffs_and_commit(dut, coeffs)
    await send_flits(dut, config_packet(3, 15, True), 'CONFIG 3-tap')
    await expect_pin(dut, CONFIG_UPDATED, 1)
    await send_flits(dut, control_packet(CTRL_RESET_FILTER), 'RESET_FILTER')
    await wait_processing(dut)

    history = []
    for sample in (4096, 8192, -4096, 16384, -8192, 0, 12000):
        await send_flits(dut, data_packet([sample]), f'FIR sample={sample}')
        history.append(sample)
        expected = fir_result(history, coeffs, 3, 15, True)
        await check_audio(dut, expected, f'3-tap history={len(history)}')


@cocotb.test()
async def test_top_eight_tap_and_saturation(dut):
    """Time-multiplexed eight-tap FIR accumulation and PCM saturation."""
    await initialize(dut)
    coeffs = [0x4000] * 8  # eight half-gain taps; clips on positive ramp
    await write_coeffs_and_commit(dut, coeffs)
    await send_flits(dut, config_packet(8, 15, True), 'CONFIG 8-tap saturating')
    await expect_pin(dut, CONFIG_UPDATED, 1)
    await send_flits(dut, control_packet(CTRL_RESET_FILTER), 'RESET_FILTER')
    await wait_processing(dut)

    history = []
    for sample in (16000, 16000, 16000, 16000, 16000, 16000, -16000, 0, 0):
        await send_flits(dut, data_packet([sample]), '8-tap DATA')
        history.append(sample)
        expected = fir_result(history, coeffs, 8, 15, True)
        await check_audio(dut, expected, f'8-tap samples={len(history)}')


@cocotb.test()
async def test_top_reset_filter_and_config_update(dut):
    """Reset FIR history without erasing programmed coefficients/config."""
    await initialize(dut)
    coeffs = [0x4000, 0x4000, 0, 0, 0, 0, 0, 0]
    await write_coeffs_and_commit(dut, coeffs)
    await send_flits(dut, config_packet(2, 15, True), 'CONFIG 2-tap')
    await expect_pin(dut, CONFIG_UPDATED, 1)
    await send_flits(dut, control_packet(CTRL_RESET_FILTER), 'initial RESET_FILTER')
    await wait_processing(dut)

    for sample, expected in [(10000, 5000), (20000, 15000)]:
        await send_flits(dut, data_packet([sample]), 'warm history')
        await check_audio(dut, expected, 'history pre-reset')

    await send_flits(dut, control_packet(CTRL_RESET_FILTER), 'second RESET_FILTER')
    await wait_processing(dut)
    await send_flits(dut, data_packet([8000]), 'post-reset sample')
    await check_audio(dut, 4000, 'history cleared, coefficients retained')

    # Change number of taps (without changing coefficients)
    await send_flits(dut, config_packet(1, 15, True), 'CONFIG one tap')
    await expect_pin(dut, CONFIG_PENDING, 0)
    await send_flits(dut, data_packet([-12000]), 'after tap change')
    await check_audio(dut, -6000, 'config update effective')


@cocotb.test()
async def test_top_status_and_control(dut):
    """One-flit commands, sticky status, and live status clearing."""
    await initialize(dut)
    await send_flits(dut, config_packet(0, 15, True), 'CONFIG')
    await expect_pin(dut, CONFIG_UPDATED, 1)
    await send_flits(dut, control_packet(CTRL_CLEAR_STATUS), 'STATUS_CLEAR')
    await expect_pin(dut, CONFIG_UPDATED, 0)

    await write_coeffs_and_commit(dut, [0x4000] + [0] * 7)
    assert bit(dut, COEFF_UPDATED) == 1
    await send_flits(dut, control_packet(CTRL_CLEAR_STATUS), 'STATUS_CLEAR')
    await expect_pin(dut, COEFF_UPDATED, 0)
    await expect_pin(dut, CONFIG_UPDATED, 0)
    assert bit(dut, COEFF_PENDING) == 0
    assert bit(dut, CONFIG_PENDING) == 0
    assert bit(dut, PROTOCOL_ERROR) == 0


@cocotb.test()
async def test_top_burst_backpressure_and_order(dut):
    """15-sample packet stresses RX FIFO, parser, FIR pacing, and ordering.

    A two-tap FIR lets the final audio output test whether the *last two*
    samples survived and remained ordered across the entire packet.
    """
    await initialize(dut)
    coeffs = [0x4000, 0x2000] + [0] * 6
    await write_coeffs_and_commit(dut, coeffs)
    await send_flits(dut, config_packet(2, 15, True), 'CONFIG 2-tap')
    await expect_pin(dut, CONFIG_UPDATED, 1)
    await send_flits(dut, control_packet(CTRL_RESET_FILTER), 'RESET_FILTER')
    await wait_processing(dut)

    rng = random.Random(298)
    samples = [rng.randrange(-16000, 16001, 16) for _ in range(15)]
    stalls = await send_flits(dut, data_packet(samples), '15-sample burst')
    dut._log.info('RX flow-control stalled host for %d cycles', stalls)
    # Stalling is ALLOWED, but isn't required; no assertion that it happened.
    expected = fir_result(samples, coeffs, 2, 15, True)
    await check_audio(dut, expected, 'burst final sample')


@cocotb.test()
async def test_top_no_ghost_flits_when_valid_low(dut):
    """Link noise while VALID=0 must never produce another DATA packet."""
    await initialize(dut)
    await send_flits(dut, config_packet(0, 0, True), 'CONFIG bypass')
    await expect_pin(dut, CONFIG_UPDATED, 1)
    await send_flits(dut, data_packet([8192]), 'one PCM word')
    await check_audio(dut, 8192, 'before idle noise')

    dut.uio_in.value = 0
    for k in range(96):
        await FallingEdge(dut.clk)
        await Timer(1, unit='ns')
        dut.ui_in.value = (k * 137 + 33) & 0xFF
    await check_audio(dut, 8192, 'VALID=0 noise ignored')
