账号级每日活跃度：同账号所有角色共享当日进度，任务只算一次，三档奖励每账号只能领一次。

注意：这是源码补丁，会修改：
- `go-server/internal/modules/dnf/activeness/state.go`
- `go-server/internal/services/dnfbridge/private_activity.go`

每次合并上游源码后需要重新选择是否应用；不选则恢复官方“按角色”行为。
