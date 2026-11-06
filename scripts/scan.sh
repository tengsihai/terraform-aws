#!/usr/bin/env bash
#
# 对整个仓库跑 Checkov，命中 scripts/checkov_gate.py 里的高危规则集时失败。
#
# 豁免以内联 `#checkov:skip=<id>:<理由>` 的形式写在代码旁边，
# 所以本脚本不携带任何全局跳过清单。

set -euo pipefail
# shellcheck source=lib.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKOV="$(find_checkov)"

stamp="$(date +%Y%m%dT%H%M%S)"
out_dir="${REPORTS_DIR}/checkov-${stamp}"
cli_report="${out_dir}/checkov-cli.txt"
mkdir -p "${out_dir}"

log "checkov scan"

set +e
"${CHECKOV}" \
  -d "${ROOT_DIR}" \
  --config-file "${ROOT_DIR}/.checkov.yaml" \
  -o cli -o json \
  --output-file-path console,"${out_dir}/results_json.json" 2>&1 | tee "${cli_report}"
scan_status=${PIPESTATUS[0]}
set -e

if [ ! -f "${out_dir}/results_json.json" ]; then
  die "checkov did not produce JSON output; treating the scan as failed"
fi

cp "${cli_report}" "${REPORTS_DIR}/checkov-latest.txt"

log "high-risk gate"
if ! python3 "${ROOT_DIR}/scripts/checkov_gate.py" "${out_dir}/results_json.json"; then
  die "Checkov high-risk gate failed. See ${cli_report}"
fi

if [ "${scan_status}" -ne 0 ]; then
  warn "checkov exited ${scan_status}: non-blocking findings remain. Review ${cli_report} and either fix them or document an inline suppression."
else
  log "checkov: no findings"
fi

log "Reports written to ${out_dir}"
