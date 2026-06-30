# progress.awk - filter CloudflareSpeedTest (cdnspeedtest) stdout into a
# clean, throttled speed-test log with overall progress.
#
# The core tool refreshes its "[n/total]" progress in place using carriage
# returns (\r). When that is captured to a file the progress is unreadable, and
# the rpcd log reader strips the bracketed numbers entirely. This filter:
#   * splits the \r-overwritten progress into discrete lines (fed via `tr`),
#   * collapses the high-frequency "[n/total]" spam into throttled
#     "进度: <phase> <tested>/<total> (<pct>%)" lines (~every 1% by default),
#   * passes through every other line (phase markers, summaries, results)
#     verbatim, so no detail is lost.
#
# Usage:  ... | tr "\r" "\n" | awk -f /usr/bin/cloudflarespeedtest/progress.awk

BEGIN {
    total = 0
    prev_total = 0
    tested = 0
    last_printed = 0
    step = 1
    phase = "测速"
}

# blank lines (e.g. produced by leading \r after the tr conversion) are noise
/^$/ {
    next
}

# progress line: contains a "[tested/total]" token
match($0, /\[[0-9]+\/[0-9]+\]/) {
    bracket = substr($0, RSTART, RLENGTH)
    inner = substr(bracket, 2, length(bracket) - 2)
    split(inner, parts, "/")
    tested = parts[1] + 0
    total = parts[2] + 0

    # detect the current phase by keyword; keep the previous label if the line
    # has no recognizable keyword (so a mangled line never resets the label)
    if (index($0, "下载") > 0)
        phase = "下载测速"
    else if (index($0, "延迟") > 0)
        phase = "延迟测速"

    # recompute the throttle step whenever the total changes (new phase)
    if (total != prev_total) {
        step = int(total / 100)
        if (step < 1)
            step = 1
        last_printed = 0
        prev_total = total
    }

    # emit progress on the first update of a phase, at every ~1% step, and at 100%
    if (total > 0 && (last_printed == 0 || tested == total || tested - last_printed >= step)) {
        pct = int(tested * 100 / total)
        printf "进度: %s %d/%d (%d%%)\n", phase, tested, total, pct
        fflush()
        last_printed = tested
    }

    next
}

# any other line: pass through verbatim (flushed on the next progress print or
# when the pipe closes, so normal output is never lost)
{
    print
}