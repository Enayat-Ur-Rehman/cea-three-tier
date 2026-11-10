#!/usr/bin/env bash
# Rolling replacement of every host in each Auto Scaling Group given, one group
# after the other. New hosts read the release tag from SSM at boot.
# Skips groups that do not exist yet (first bootstrap run).
set -euo pipefail

refresh() {
  local asg="$1" found id status
  found=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
          --query 'length(AutoScalingGroups)' --output text)
  if [ "$found" = "0" ]; then
    echo "::warning::$asg does not exist yet (first bootstrap run). Skipping."
    return 0
  fi

  # A refresh left running by an earlier failed run would block a new one.
  id=$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$asg" \
       --query "InstanceRefreshes[?Status=='InProgress' || Status=='Pending'] | [0].InstanceRefreshId" \
       --output text)
  if [ "$id" != "None" ] && [ -n "$id" ]; then
    echo "Cancelling unfinished refresh $id on $asg"
    cancel_and_wait "$asg"
  fi

  id=$(aws autoscaling start-instance-refresh --auto-scaling-group-name "$asg" \
       --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":120}' \
       --query InstanceRefreshId --output text)
  echo "Started instance refresh $id on $asg"
  for _ in $(seq 1 60); do
    status=$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$asg" \
             --instance-refresh-ids "$id" --query 'InstanceRefreshes[0].Status' --output text)
    echo "$asg: $status"
    case "$status" in
      Successful) return 0 ;;
      Failed|Cancelled|RollbackSuccessful|RollbackFailed)
        echo "::error::$asg refresh $status"; return 1 ;;
    esac
    sleep 20
  done
  echo "::error::Timed out waiting for $asg, cancelling the refresh"
  cancel_and_wait "$asg"
  return 1
}

cancel_and_wait() {
  local asg="$1" status
  aws autoscaling cancel-instance-refresh --auto-scaling-group-name "$asg" >/dev/null || true
  for _ in $(seq 1 30); do
    status=$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$asg" \
             --max-records 1 --query 'InstanceRefreshes[0].Status' --output text)
    case "$status" in Cancelling|InProgress|Pending) sleep 10 ;; *) return 0 ;; esac
  done
}

for asg in "$@"; do
  refresh "$asg"
done
