#!/usr/bin/env bash
# Rolling replacement of every host in the Auto Scaling Groups given.
# All groups are refreshed at the same time. Inside each group the new hosts are
# launched first (MaxHealthyPercentage 200) and the old hosts are removed only
# after the new ones pass the load balancer health check (MinHealthyPercentage
# 100), so capacity never drops during a deploy. New hosts read the release tag
# from SSM at boot. Groups that do not exist yet (first bootstrap run) are skipped.
set -euo pipefail

PREFS='{"MinHealthyPercentage":100,"MaxHealthyPercentage":200,"InstanceWarmup":30}'

cancel_and_wait() {
  local asg="$1" status
  aws autoscaling cancel-instance-refresh --auto-scaling-group-name "$asg" >/dev/null || true
  for _ in $(seq 1 30); do
    status=$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$asg" \
             --max-records 1 --query 'InstanceRefreshes[0].Status' --output text)
    case "$status" in Cancelling|InProgress|Pending) sleep 10 ;; *) return 0 ;; esac
  done
}

declare -A REFRESH=()

for asg in "$@"; do
  found=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
          --query 'length(AutoScalingGroups)' --output text)
  if [ "$found" = "0" ]; then
    echo "::warning::$asg does not exist yet (first bootstrap run). Skipping."
    continue
  fi
  # A refresh left running by an earlier failed run would block a new one.
  id=$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$asg" \
       --query "InstanceRefreshes[?Status=='InProgress' || Status=='Pending'] | [0].InstanceRefreshId" \
       --output text)
  if [ "$id" != "None" ] && [ -n "$id" ]; then
    echo "Cancelling unfinished refresh $id on $asg"
    cancel_and_wait "$asg"
  fi
  REFRESH[$asg]=$(aws autoscaling start-instance-refresh --auto-scaling-group-name "$asg" \
                  --preferences "$PREFS" --query InstanceRefreshId --output text)
  echo "Started instance refresh ${REFRESH[$asg]} on $asg"
done

[ "${#REFRESH[@]}" -eq 0 ] && exit 0

# Poll all groups together, up to 15 minutes
for _ in $(seq 1 60); do
  pending=0
  for asg in "${!REFRESH[@]}"; do
    read -r status pct < <(aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$asg" \
      --instance-refresh-ids "${REFRESH[$asg]}" \
      --query 'InstanceRefreshes[0].[Status,PercentageComplete]' --output text)
    echo "$asg: $status ${pct}%"
    case "$status" in
      Successful) unset "REFRESH[$asg]" ;;
      Failed|Cancelled|RollbackSuccessful|RollbackFailed)
        echo "::error::$asg refresh $status"
        for other in "${!REFRESH[@]}"; do [ "$other" != "$asg" ] && cancel_and_wait "$other"; done
        exit 1 ;;
      *) pending=1 ;;
    esac
  done
  [ "$pending" -eq 0 ] && { echo "All groups refreshed"; exit 0; }
  sleep 15
done

echo "::error::Timed out waiting for the refresh, cancelling"
for asg in "${!REFRESH[@]}"; do cancel_and_wait "$asg"; done
exit 1
