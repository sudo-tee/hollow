// Snapshot round-trip check for a recorded PTY stream.
//
// usage: session-snapshot-spike <recording> <cols> <rows> [cut] [resize_cols resize_rows]
//
// Feeds recording[0..cut) into a source terminal (optionally resizing it
// afterwards, as if the client changed size while detached), encodes a
// snapshot, restores it incrementally into a second terminal, and compares
// the two. Then feeds recording[cut..] into both and compares again, then
// forces both back to the primary screen and restores the saved cursor.
// cut defaults to the whole recording; a negative cut counts from the end.

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ghostty/vt.h>

#define CHECK(expr)                                                       \
  do {                                                                    \
    GhosttyResult r_ = (expr);                                            \
    if (r_ != GHOSTTY_SUCCESS) {                                          \
      fprintf(stderr, "%s:%d: %s -> %d\n", __FILE__, __LINE__, #expr, r_); \
      exit(2);                                                            \
    }                                                                     \
  } while (0)

static int failures = 0;

static double now_ms(void) {
  struct timespec ts;
  timespec_get(&ts, TIME_UTC);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static uint8_t *read_file(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    perror(path);
    exit(2);
  }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *buf = malloc(n > 0 ? (size_t)n : 1);
  if (fread(buf, 1, (size_t)n, f) != (size_t)n) exit(2);
  fclose(f);
  *len = (size_t)n;
  return buf;
}

static GhosttyTerminal new_source(uint16_t cols, uint16_t rows) {
  GhosttyTerminal t = NULL;
  CHECK(ghostty_terminal_new(NULL, &t, cols, rows));
  const size_t continuation = 4096;
  CHECK(ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation));
  const size_t scrollback = 16 * 1024 * 1024;
  CHECK(ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback));
  return t;
}

static void format(GhosttyTerminal t, bool vt, uint8_t **out, size_t *len) {
  GhosttyFormatterTerminalOptions opts = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
  opts.emit = vt ? GHOSTTY_FORMATTER_FORMAT_VT : GHOSTTY_FORMATTER_FORMAT_PLAIN;
  opts.extra = (GhosttyFormatterTerminalExtra)GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalExtra);
  opts.extra.palette = vt;
  opts.extra.modes = vt;
  opts.extra.scrolling_region = vt;
  opts.extra.tabstops = vt;
  opts.extra.pwd = vt;
  opts.extra.keyboard = vt;
  opts.extra.screen = (GhosttyFormatterScreenExtra)GHOSTTY_INIT_SIZED(GhosttyFormatterScreenExtra);
  opts.extra.screen.cursor = vt;
  opts.extra.screen.style = vt;
  opts.extra.screen.hyperlink = vt;
  opts.extra.screen.protection = vt;
  opts.extra.screen.kitty_keyboard = vt;
  opts.extra.screen.charsets = vt;
  GhosttyFormatter f = NULL;
  CHECK(ghostty_formatter_terminal_new(NULL, &f, t, opts));
  CHECK(ghostty_formatter_format_alloc(f, NULL, out, len));
  ghostty_formatter_free(f);
}

static bool same_bytes(const uint8_t *a, size_t al, const uint8_t *b, size_t bl) {
  return al == bl && (al == 0 || memcmp(a, b, al) == 0);
}

static bool same_string(GhosttyTerminal a, GhosttyTerminal b, GhosttyTerminalData key) {
  GhosttyString sa = {0}, sb = {0};
  CHECK(ghostty_terminal_get(a, key, &sa));
  // Copy before the next terminal call can invalidate the borrowed pointer.
  char *ca = malloc(sa.len + 1);
  memcpy(ca, sa.ptr, sa.len);
  CHECK(ghostty_terminal_get(b, key, &sb));
  bool ok = sa.len == sb.len && memcmp(ca, sb.ptr, sb.len) == 0;
  free(ca);
  return ok;
}

static void expect(const char *stage, const char *what, bool ok) {
  if (!ok) {
    failures++;
    printf("  FAIL %-10s %s\n", stage, what);
  }
}

static void compare(const char *stage, GhosttyTerminal a, GhosttyTerminal b) {
  uint8_t *fa, *fb;
  size_t la, lb;
  format(a, true, &fa, &la);
  format(b, true, &fb, &lb);
  bool vt_same = same_bytes(fa, la, fb, lb);
  expect(stage, "vt format (active screen + scrollback + extras)", vt_same);
  if (!vt_same) {
    // Is the shorter output a suffix of the longer (only oldest history differs)?
    const uint8_t *lo = la > lb ? fa : fb, *sh = la > lb ? fb : fa;
    size_t ll = la > lb ? la : lb, sl = la > lb ? lb : la;
    size_t common = 0;
    while (common < sl && lo[ll - 1 - common] == sh[sl - 1 - common]) common++;
    printf("  note %-10s vt %zu vs %zu bytes, common suffix %zu\n", stage, la, lb, common);
  }
  ghostty_free(NULL, fa, la);
  ghostty_free(NULL, fb, lb);

  expect(stage, "title", same_string(a, b, GHOSTTY_TERMINAL_DATA_TITLE));
  expect(stage, "pwd", same_string(a, b, GHOSTTY_TERMINAL_DATA_PWD));

  const GhosttyTerminalData keys[] = {
      GHOSTTY_TERMINAL_DATA_COLS, GHOSTTY_TERMINAL_DATA_ROWS,
      GHOSTTY_TERMINAL_DATA_CURSOR_X, GHOSTTY_TERMINAL_DATA_CURSOR_Y,
      GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE,
      GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS,
  };
  const char *names[] = {"cols", "rows", "cursor_x", "cursor_y", "active_screen",
                         "cursor_visible", "mouse_tracking", "scrollback_rows"};
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
    uint64_t va = 0, vb = 0;  // wide enough for every key above
    CHECK(ghostty_terminal_get(a, keys[i], &va));
    CHECK(ghostty_terminal_get(b, keys[i], &vb));
    expect(stage, names[i], va == vb);
    if (va != vb) printf("  note %-10s %s %llu vs %llu\n", stage, names[i], (unsigned long long)va, (unsigned long long)vb);
  }

  uint8_t *ea, *eb;
  size_t lea, leb;
  CHECK(ghostty_snapshot_encode_alloc(a, NULL, &ea, &lea));
  CHECK(ghostty_snapshot_encode_alloc(b, NULL, &eb, &leb));
  if (!same_bytes(ea, lea, eb, leb)) {
    size_t i = 0;
    while (i < lea && i < leb && ea[i] == eb[i]) i++;
    printf("  note %-10s re-encode differs: %zu vs %zu bytes, first diff at %zu\n", stage, lea, leb, i);
    if (getenv("SPIKE_DUMP")) {
      FILE *fa_ = fopen("/tmp/opencode/rec/a.snap", "wb"), *fb_ = fopen("/tmp/opencode/rec/b.snap", "wb");
      fwrite(ea, 1, lea, fa_);
      fwrite(eb, 1, leb, fb_);
      fclose(fa_);
      fclose(fb_);
    }
  }
  ghostty_free(NULL, ea, lea);
  ghostty_free(NULL, eb, leb);
}

static void feed(GhosttyTerminal a, GhosttyTerminal b, const uint8_t *p, size_t n) {
  ghostty_terminal_vt_write(a, p, n);
  ghostty_terminal_vt_write(b, p, n);
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s <recording> <cols> <rows> [cut] [resize_cols resize_rows]\n", argv[0]);
    return 2;
  }
  size_t len;
  uint8_t *data = read_file(argv[1], &len);
  uint16_t cols = (uint16_t)atoi(argv[2]), rows = (uint16_t)atoi(argv[3]);
  long long cut_arg = argc > 4 ? atoll(argv[4]) : (long long)len;
  size_t cut = cut_arg < 0 ? len - (size_t)(-cut_arg) : (size_t)cut_arg;
  if (cut > len) cut = len;

  GhosttyTerminal source = new_source(cols, rows);
  ghostty_terminal_vt_write(source, data, cut);
  if (argc > 6) CHECK(ghostty_terminal_resize(source, (uint16_t)atoi(argv[5]), (uint16_t)atoi(argv[6]), 8, 16));

  bool ground = false;
  CHECK(ghostty_terminal_get(source, GHOSTTY_TERMINAL_DATA_VT_GROUND, &ground));

  double t0 = now_ms();
  uint8_t *snap;
  size_t snap_len;
  CHECK(ghostty_snapshot_encode_alloc(source, NULL, &snap, &snap_len));
  double t1 = now_ms();
  // Cross-target check: SPIKE_WRITE saves the snapshot; SPIKE_READ decodes a
  // snapshot produced by another build (e.g. Linux owner -> Windows client).
  if (getenv("SPIKE_WRITE")) {
    FILE *w = fopen(getenv("SPIKE_WRITE"), "wb");
    fwrite(snap, 1, snap_len, w);
    fclose(w);
  }
  if (getenv("SPIKE_READ")) {
    ghostty_free(NULL, snap, snap_len);
    uint8_t *other = read_file(getenv("SPIKE_READ"), &snap_len);
    snap = ghostty_alloc(NULL, snap_len);
    memcpy(snap, other, snap_len);
    free(other);
  }

  GhosttySnapshotDecoder dec = NULL;
  CHECK(ghostty_snapshot_decoder_new_buf(NULL, &dec, snap, snap_len));
  // Keep tracking on the restored terminal so it can itself be re-encoded.
  const bool retain = true;
  CHECK(ghostty_snapshot_decoder_set(dec, GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain));
  GhosttyTerminal restored = NULL;
  CHECK(ghostty_snapshot_decoder_ready(dec, &restored));
  // Scrollback limits are not part of the snapshot; the decoder side applies
  // its own. SPIKE_NO_LIMIT=1 skips this to show the divergence.
  if (!getenv("SPIKE_NO_LIMIT")) {
    size_t max_bytes = 0;
    CHECK(ghostty_terminal_get(source, GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES, &max_bytes));
    CHECK(ghostty_terminal_set(restored, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &max_bytes));
  }
  double t2 = now_ms();
  size_t pages = 0;
  GhosttyResult r;
  while ((r = ghostty_snapshot_decoder_next(dec)) == GHOSTTY_SUCCESS) pages++;
  if (r != GHOSTTY_NO_VALUE) {
    fprintf(stderr, "decoder_next -> %d\n", r);
    return 2;
  }
  double t3 = now_ms();
  ghostty_snapshot_decoder_free(dec);

  uint64_t screen = 0, sb_rows = 0;
  CHECK(ghostty_terminal_get(source, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen));
  CHECK(ghostty_terminal_get(source, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &sb_rows));
  printf("%s: %zu/%zu bytes fed, ground=%d, active_screen=%llu, scrollback_rows=%llu\n",
         argv[1], cut, len, ground, (unsigned long long)screen, (unsigned long long)sb_rows);
  printf("  snapshot %zu bytes, encode %.2f ms, ready %.2f ms, history %zu pages %.2f ms\n",
         snap_len, t1 - t0, t2 - t1, pages, t3 - t2);

  compare("restore", source, restored);
  feed(source, restored, data + cut, len - cut);
  compare("tail", source, restored);
  // Leave the alt screen (if any) and restore the saved cursor, then draw.
  static const char epilogue[] = "\x1b[?1049l\x1b" "8@saved-cursor@";
  feed(source, restored, (const uint8_t *)epilogue, sizeof(epilogue) - 1);
  compare("primary", source, restored);

  // Fallback path: replay the VT formatter output of the source into a fresh
  // terminal. Only the active screen, scrollback, and cursor are expected.
  {
    uint16_t fc = 0, fr = 0;
    CHECK(ghostty_terminal_get(source, GHOSTTY_TERMINAL_DATA_COLS, &fc));
    CHECK(ghostty_terminal_get(source, GHOSTTY_TERMINAL_DATA_ROWS, &fr));
    GhosttyTerminal fresh = new_source(fc, fr);
    uint8_t *vt, *pa, *pb;
    size_t vl, pal, pbl;
    format(source, true, &vt, &vl);
    ghostty_terminal_vt_write(fresh, vt, vl);
    format(source, false, &pa, &pal);
    format(fresh, false, &pb, &pbl);
    expect("fallback", "plain text (screen + scrollback)", same_bytes(pa, pal, pb, pbl));
    const GhosttyTerminalData keys[] = {GHOSTTY_TERMINAL_DATA_CURSOR_X, GHOSTTY_TERMINAL_DATA_CURSOR_Y,
                                        GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS};
    const char *names[] = {"cursor_x", "cursor_y", "scrollback_rows"};
    for (size_t i = 0; i < 3; i++) {
      uint64_t va = 0, vb = 0;
      CHECK(ghostty_terminal_get(source, keys[i], &va));
      CHECK(ghostty_terminal_get(fresh, keys[i], &vb));
      expect("fallback", names[i], va == vb);
    }
    printf("  fallback vt %zu bytes\n", vl);
    ghostty_free(NULL, vt, vl);
    ghostty_free(NULL, pa, pal);
    ghostty_free(NULL, pb, pbl);
    ghostty_terminal_free(fresh);
  }

  printf("  %s\n", failures ? "FAILED" : "ok");
  ghostty_free(NULL, snap, snap_len);
  ghostty_terminal_free(restored);
  ghostty_terminal_free(source);
  free(data);
  return failures ? 1 : 0;
}
