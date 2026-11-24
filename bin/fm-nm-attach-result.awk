# Classify one drive stdout (ARGV[1]) against the subsequent axi status stdout.
# Read only the TOON fields used by this decision, at their declared depth.
# A duplicate scalar or run block cannot identify a unique observation.
function record(key, value) {
    if ((doc, key) in field) invalid[doc] = 1
    if (value ~ /^"[^"]*"$/) value = substr(value, 2, length(value)-2)
    if (value == "") invalid[doc] = 1
    field[doc, key] = value
}
function scalar(start, prefix,    colon) {
    colon = index($0, ":")
    if (substr($0, colon, 2) != ": ") invalid[doc] = 1
    record(prefix substr($0, start, colon-start), substr($0, colon+2))
}
FNR == 1 { doc = (FILENAME == ARGV[1] ? "drive" : "status"); section = table = "" }
/^[^ ]/ {
    section = $0
    table = ""
    if ($0 == "run:") record("run", "yes")
    if (/^(other_branch_run:|current_branch:|runs\[)/) foreign[doc] = 1
    if ($0 == "gate:") record("gate", "yes")
    if (/^(error|outcome):/) scalar(1, "")
    next
}
/^  [^ ]/ {
    table = ""
    if (section == "run:" && /^  steps\[[0-9]+\]\{step,status,[^}]+\}:$/) table = "steps"
    if (section == "run:" && /^  (id|branch|status|head|head_sha):/) scalar(3, "")
    if (section == "branch_sync:" && /^  state: (remote_advanced|remote_rewritten|target_changed)$/) superseded[doc] = 1
    if (section == "gate:" && /^  (step|status):/) scalar(3, "gate_")
    next
}
table == "steps" && /^    [[:alnum:]_-]+,/ {
    if (split(substr($0, 5), row, ",") < 4) invalid[doc] = 1
    if (row[2] == "awaiting_approval" || row[2] == "fix_review") {
        parked_step[doc] = row[1]
        parked_state[doc] = row[2]
    }
    if (row[2] == "failed" || row[2] == "cancelled") failed_step[doc] = row[1]
    if (row[2] == "running" || row[2] == "fixing" || row[2] == "ci") {
        if (active[doc] != "") multiple_active[doc] = 1
        active[doc] = row[1]
    }
}

# The CLI displays eight hex digits in head and supplies the full SHA in
# head_sha on newer records. Require a full anchor in at least one observation.
function head(doc,    shortsha, fullsha) {
    if ((doc,"head") in field) {
        shortsha = field[doc,"head"]
        if (shortsha !~ /^[0-9a-f]+$/ || (length(shortsha) != 8 && length(shortsha) != 40)) return ""
    }
    if ((doc,"head_sha") in field) {
        fullsha = field[doc,"head_sha"]
        if (length(fullsha) != 40 || fullsha !~ /^[0-9a-f]+$/) return ""
    }
    if (fullsha == "") return shortsha
    if (shortsha != "" && index(fullsha, shortsha) != 1) return ""
    return fullsha
}
function same_head(    a,b) {
    a = head("drive")
    b = head("status")
    return a != "" && b != "" && ((length(a) == 40 && index(a,b) == 1) || (length(b) == 40 && index(b,a) == 1))
}
function monitoring(doc) {
    return (field[doc,"status"] == "running" && active[doc] == "ci" && !multiple_active[doc] &&
            !superseded[doc] && !parked_step[doc] && !failed_step[doc] && !field[doc,"gate"] && !field[doc,"error"])
}
# Emit the observation, run id, and its step/state or error for the follower.
function classify(    id,state,outcome,err,step,gate_state) {
    id = field["status","id"]
    state = field["status","status"]
    outcome = field["status","outcome"]
    err = field["status","error"]
    if (status_rc || (!field["status","run"] && !foreign["status"]))
        return "daemon " (id ? id : "unknown")
    if (foreign["status"] || !id || field["status","branch"] != "fm/" task)
        return "absent"
    if (invalid["status"] || state !~ /^[a-z_]+$/ || id !~ /^[[:alnum:]]+$/)
        return "ambiguous"
    if (state == "failed" || state == "cancelled")
        return "failed " id " " state " " err
    if (err || (outcome && outcome != "passed" && outcome != "checks-passed"))
        return "failed " id " " (outcome ? outcome : state) " " err
    if (field["status","gate"] || parked_step["status"] || state == "awaiting_approval" || state == "fix_review") {
        step = parked_step["status"]
        gate_state = parked_state["status"]
        if (!step) step = field["status","gate_step"]
        if (!gate_state) gate_state = field["status","gate_status"]
        return "gate " id " " (step ? step : state) " " (gate_state ? gate_state : state)
    }
    if (failed_step["status"]) return "failed " id " failed at " failed_step["status"]
    if (superseded["status"]) return "unconfirmed " id
    if (outcome == "passed" || (state == "completed" && outcome == ""))
        return "passed " id " " (outcome ? outcome : state)

    if (!drive_rc && !invalid["drive"] && !foreign["drive"] && field["drive","outcome"] == "checks-passed" &&
        field["drive","id"] == id && field["drive","branch"] == "fm/" task && monitoring("drive") && monitoring("status") && same_head())
        return "passed " id " checks-passed"

    if (drive_rc && !invalid["drive"] && field["drive","error"] ~ /^wait of [^ ]+ elapsed while driving the run$/) {
        step = active["status"]
        return "elapsed " id " " state " " (step ? step : state)
    }
    return "unconfirmed " id
}
END { print classify() }
