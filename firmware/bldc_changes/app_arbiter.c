/*
 * RC-failsafe arbiter (F1TENTH) — included via APP_CUSTOM_TO_USE.
 * ----------------------------------------------------------------------------
 * Reads an ELRS receiver (CRSF @ 420000, 8N1) directly on the COMM UART
 * (USART3, PB11 = RX) and arbitrates between the RC transmitter and the
 * computer (which sends standard motor/servo commands over USB comm).
 *
 * Both inputs are ALWAYS received. A joy switch (mode channel) selects which
 * one drives the output; the arbiter is the single writer to motor & servo.
 *
 *   ch0 = steering   ch2 = throttle   ch5 = arm (master/estop)   ch6 = mode
 *
 * Priority: RC lost > disarmed > MANUAL(RC) > AUTO(computer, if fresh)
 *           > AUTO but computer dead -> RC fallback
 *
 * When the arbiter drives (manual or failover), app_arbiter_blocks_comm()
 * returns true and commands.c ignores computer motor/servo commands so the
 * two never fight. Requires "App to Use = Custom" and servo output enabled.
 *
 * Note: on this HW the CURRENT_FILTER macro toggles PB11 via palClearPad,
 * which is a no-op while the pin is in UART alternate-function mode, so motor
 * operation does not disturb CRSF reception.
 */

#include "app.h"
#include "ch.h"
#include "hal.h"

#include "mc_interface.h"
#include "utils_math.h"
#include "hw.h"
#include "commands.h"
#include "terminal.h"
#include "timeout.h"
#include "buffer.h"
#include "driver/pwm_servo.h"

#include <math.h>
#include <string.h>

// ---- CRSF ----
#define CRSF_SYNC        0xC8
#define CRSF_TYPE_RC     0x16
#define CRSF_BAUD        420000

// ---- channel map (0-based) ----
#define CH_STEER  0
#define CH_THR    2
#define CH_ARM    5
#define CH_MODE   6

// ---- tuning ----
#define STR_RANGE      0.35f   // servo travel about 0.5 center
#define THR_MAX        0.30f   // motor current-rel cap (raise after bring-up)
#define DEADBAND       0.05f
#define SW_HIGH        1500    // switch HIGH threshold (CRSF ~172..1811)
#define RC_TIMEOUT_MS  100     // RC frame loss
#define CMD_TIMEOUT_MS 500     // computer command loss (auto -> RC fallback)

// ---- gate state shared with commands.c ----
static volatile bool arbiter_driving = false;
static volatile systime_t last_comm_cmd = 0;
static volatile uint32_t comm_cmd_count = 0;   // debug: how many comm motor/servo cmds seen

bool app_arbiter_blocks_comm(void) {
	return arbiter_driving;
}

void app_arbiter_report_comm_cmd(void) {
	last_comm_cmd = chVTGetSystemTimeX();
	comm_cmd_count++;
}

// ---- telemetry back to PC (so it sees servo/throttle/mode in every mode) ----
// mode: 0=disarm/stop, 1=manual(RC), 2=auto(computer), 3=auto-failover(RC)
static volatile int arb_mode = 0;
static volatile float g_servo = 0.5f;   // last applied servo (arbiter or comm passthrough)

// Called by commands.c when an auto (passthrough) servo command is applied,
// so the reported servo matches reality in auto mode too.
void app_arbiter_note_servo(float pos) {
	g_servo = pos;
}

// ---- private ----
static THD_FUNCTION(arbiter_thread, arg);
static THD_WORKING_AREA(arbiter_thread_wa, 2048);
static volatile bool stop_now = true;
static volatile bool is_running = false;

static uint16_t rc_ch[16];
static systime_t last_rc_frame = 0;
static uint8_t rxbuf[64];
static int rxlen = 0;

static uint16_t crsf_unpack(const uint8_t *pl, int i) {
	int bo = (i * 11) / 8;
	int sh = (i * 11) % 8;
	uint32_t v = (uint32_t)pl[bo] >> sh;
	v |= (uint32_t)pl[bo + 1] << (8 - sh);
	v |= (uint32_t)pl[bo + 2] << (16 - sh);
	return (uint16_t)(v & 0x7FF);
}

static void crsf_parse(void) {
	while (rxlen >= 4) {
		if (rxbuf[0] != CRSF_SYNC) {
			memmove(rxbuf, rxbuf + 1, --rxlen);
			continue;
		}
		int flen = rxbuf[1];              // type + payload + crc
		if (flen < 2 || flen > 62) {
			memmove(rxbuf, rxbuf + 1, --rxlen);
			continue;
		}
		int total = 2 + flen;
		if (rxlen < total) {
			break;                        // wait for the rest of the frame
		}
		if (rxbuf[2] == CRSF_TYPE_RC) {   // RC channels packed (22B payload)
			for (int i = 0; i < 16; i++) {
				rc_ch[i] = crsf_unpack(&rxbuf[3], i);
			}
			last_rc_frame = chVTGetSystemTimeX();
		}
		memmove(rxbuf, rxbuf + total, rxlen - total);
		rxlen -= total;
	}
}

static float rc_norm(uint16_t raw) {      // 172..1811 (center 992) -> -1..1
	float x = ((float)raw - 992.0f) / 819.0f;
	if (x > 1.0f) x = 1.0f;
	if (x < -1.0f) x = -1.0f;
	return x;
}
static float deadband(float x) {
	return (fabsf(x) < DEADBAND) ? 0.0f : x;
}

static void drive_rc(void) {
	float st = rc_norm(rc_ch[CH_STEER]);
	float th = deadband(rc_norm(rc_ch[CH_THR]));
	float servo = 0.5f + STR_RANGE * st;
	pwm_servo_set_servo_out(servo);
	mc_interface_set_current_rel(THR_MAX * th);
	g_servo = servo;
	timeout_reset();
}
static void stop_out(void) {
	mc_interface_set_current_rel(0.0f);
	pwm_servo_set_servo_out(0.5f);
	g_servo = 0.5f;
	timeout_reset();
}

// Send [0xA5, mode, servo*1000, rc_steer*1000, rc_throttle*1000] to the PC.
static void send_feedback(void) {
	uint8_t buf[8];
	int32_t ind = 0;
	buf[ind++] = 0xA5;                 // marker for the RC-arbiter feedback packet
	buf[ind++] = (uint8_t)arb_mode;
	buffer_append_int16(buf, (int16_t)(g_servo * 1000.0f), &ind);
	buffer_append_int16(buf, (int16_t)(rc_norm(rc_ch[CH_STEER]) * 1000.0f), &ind);
	buffer_append_int16(buf, (int16_t)(deadband(rc_norm(rc_ch[CH_THR])) * 1000.0f), &ind);
	commands_send_app_data(buf, ind);
}

// VESC Tool terminal command: toggle periodic (1 s) arbiter state print.
static volatile bool dbg_on = false;
static int dbg_tick = 0;
static int fb_tick = 0;

static void arb_print_state(void) {
	int age = ST2MS(chVTTimeElapsedSinceX(last_rc_frame));
	int cmd_age = ST2MS(chVTTimeElapsedSinceX(last_comm_cmd));
	commands_printf("steer %d thr %d arm %d mode %d | rc_age %d cmd_age %d cmds %lu driving %d",
			rc_ch[CH_STEER], rc_ch[CH_THR], rc_ch[CH_ARM], rc_ch[CH_MODE],
			age, cmd_age, (unsigned long)comm_cmd_count, arbiter_driving);
}

static void terminal_arb(int argc, const char **argv) {
	(void)argc; (void)argv;
	dbg_on = !dbg_on;
	commands_printf("arb periodic print %s", dbg_on ? "ON (type arb again to stop)" : "OFF");
	arb_print_state();
}

void app_custom_start(void) {
	stop_now = false;

	terminal_register_command_callback(
			"arb", "Print RC arbiter state", 0, terminal_arb);

	// Take over the COMM UART for CRSF RX (USART3, PB11).
	static SerialConfig uart_cfg = { CRSF_BAUD, 0, 0, 0 }; // 8N1
	sdStop(&HW_UART_DEV);
	sdStart(&HW_UART_DEV, &uart_cfg);
	palSetPadMode(HW_UART_RX_PORT, HW_UART_RX_PIN,
			PAL_MODE_ALTERNATE(HW_UART_GPIO_AF) |
			PAL_STM32_OSPEED_HIGHEST | PAL_STM32_PUDR_PULLUP);

	chThdCreateStatic(arbiter_thread_wa, sizeof(arbiter_thread_wa),
			NORMALPRIO, arbiter_thread, NULL);
}

void app_custom_stop(void) {
	terminal_unregister_callback(terminal_arb);
	stop_now = true;
	while (is_running) {
		chThdSleepMilliseconds(1);
	}
}

void app_custom_configure(app_configuration *conf) {
	(void)conf;
}

static THD_FUNCTION(arbiter_thread, arg) {
	(void)arg;
	chRegSetThreadName("RC Arbiter");
	is_running = true;

	// center channels so a first cycle before any frame is safe
	for (int i = 0; i < 16; i++) {
		rc_ch[i] = 992;
	}

	for (;;) {
		if (stop_now) {
			is_running = false;
			return;
		}

		// 1) drain UART (non-blocking) and parse CRSF
		msg_t r;
		while ((r = sdGetTimeout(&HW_UART_DEV, TIME_IMMEDIATE)) != MSG_TIMEOUT) {
			if (rxlen < (int)sizeof(rxbuf)) {
				rxbuf[rxlen++] = (uint8_t)r;
			} else {
				memmove(rxbuf, rxbuf + 1, sizeof(rxbuf) - 1);
				rxbuf[sizeof(rxbuf) - 1] = (uint8_t)r;
			}
		}
		crsf_parse();

		// 2) freshness
		bool rc_alive = ST2MS(chVTTimeElapsedSinceX(last_rc_frame)) < RC_TIMEOUT_MS;
		bool cmd_fresh = ST2MS(chVTTimeElapsedSinceX(last_comm_cmd)) < CMD_TIMEOUT_MS;
		bool armed = rc_ch[CH_ARM] > SW_HIGH;
		bool automode = rc_ch[CH_MODE] > SW_HIGH;

		// 3) arbitrate (single writer)
		if (!rc_alive) {
			arbiter_driving = true;         // RC lost -> hold & stop
			arb_mode = 0;
			stop_out();
		} else if (!armed) {
			arbiter_driving = true;         // disarmed / estop
			arb_mode = 0;
			stop_out();
		} else if (!automode) {
			arbiter_driving = true;         // MANUAL: RC drives
			arb_mode = 1;
			drive_rc();
		} else if (!cmd_fresh) {
			arbiter_driving = true;         // AUTO but computer dead -> RC fallback
			arb_mode = 3;
			drive_rc();
		} else {
			arbiter_driving = false;        // AUTO: computer drives via comm (stay out)
			arb_mode = 2;
		}

		// 4) telemetry back to PC at 50 Hz (every 4th 5 ms cycle)
		if (++fb_tick >= 4) {
			fb_tick = 0;
			send_feedback();
		}

		// periodic debug print (toggled by the "arb" terminal command)
		if (dbg_on) {
			if (++dbg_tick >= 200) {        // 200 * 5 ms = 1 s
				dbg_tick = 0;
				arb_print_state();
			}
		} else {
			dbg_tick = 0;
		}

		chThdSleepMilliseconds(5);          // 200 Hz
	}
}
