"""Optional feature: account-wide daily activeness."""
from pathlib import Path
import sys

MARK = "DNF90 optional patch: account-wide activeness"


def patch_state(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARK in text:
        print(f"[skip] {path.name} already patched")
        return
    anchor = 'func progressKey(id int) string { return prefix + "progress_" + strconv.Itoa(id) }\n'
    assert anchor in text, f"anchor not found in {path}"
    addition = anchor + '''
// DNF90 optional patch: account-wide activeness
// MergeAccountActivity folds sibling characters' private-activity state into
// dst so every character of one account shares the same daily progress and
// claim bits. Callers persist dst; siblings are merged on their next view.
func MergeAccountActivity(dst *repo.CharacterRecord, siblings []repo.CharacterRecord, c *Catalog, now time.Time) (bool, error) {
	if dst == nil || c == nil || c.Fingerprint <= 0 || now.IsZero() {
		return false, ErrState
	}
	if err := initState(dst, c, now); err != nil {
		return false, err
	}
	day := dst.Stats[prefix+"day"]
	changed := false
	set := func(key string, value int64) {
		if value < 0 {
			value = 0
		}
		if dst.Stats[key] != value {
			dst.Stats[key] = value
			changed = true
		}
	}
	for i := range siblings {
		other := siblings[i]
		if other.CharacterID == dst.CharacterID || other.Stats == nil || other.Stats["delete_flag"] != 0 {
			continue
		}
		if other.Stats[prefix+"day"] != day || other.Stats[prefix+"fingerprint"] != c.Fingerprint {
			continue
		}
		set(prefix+"claimed", dst.Stats[prefix+"claimed"]|other.Stats[prefix+"claimed"])
		set(prefix+"rules011_prior_claimed", dst.Stats[prefix+"rules011_prior_claimed"]|other.Stats[prefix+"rules011_prior_claimed"])
		set(prefix+"done", dst.Stats[prefix+"done"]|other.Stats[prefix+"done"])
		for task := 1; task <= 8; task++ {
			key := progressKey(task)
			if other.Stats[key] > dst.Stats[key] {
				set(key, other.Stats[key])
			}
		}
	}
	done := dst.Stats[prefix+"done"]
	points := int64(0)
	for i, task := range c.Tasks {
		key := progressKey(i + 1)
		progress := dst.Stats[key]
		if progress > int64(task.Target) {
			progress = int64(task.Target)
		}
		if done&(1<<i) != 0 || progress == int64(task.Target) {
			progress = int64(task.Target)
			done |= 1 << i
			points += int64(task.Points)
		} else {
			done &^= 1 << i
		}
		set(key, progress)
	}
	set(prefix+"done", done)
	set(prefix+"points", points)
	set(prefix+"claimed", dst.Stats[prefix+"claimed"]&7)
	set(prefix+"rules011_prior_claimed", dst.Stats[prefix+"rules011_prior_claimed"]&7)
	return changed, nil
}
'''
    path.write_text(text.replace(anchor, addition, 1), encoding="utf-8")
    print(f"[patch] {path.name}")


def patch_bridge(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARK in text:
        print(f"[skip] {path.name} already patched")
        return

    old_apply = '''func (s *Service) applyPrivateActivity(ch *repo.CharacterRecord, id uint16, amount uint32, now, eventAt time.Time) (bool, error) {
	c, err := s.privateActivityCatalog()
	if err != nil {
		return false, err
	}
	return activeness.Apply(ch, c, id, amount, now, eventAt)
}'''
    new_apply = '''func (s *Service) applyPrivateActivity(ch *repo.CharacterRecord, id uint16, amount uint32, now, eventAt time.Time) (bool, error) {
	c, err := s.privateActivityCatalog()
	if err != nil {
		return false, err
	}
	// DNF90 optional patch: account-wide activeness
	if err := s.mergeAccountPrivateActivity(context.Background(), ch, c, now); err != nil && s.logger != nil {
		s.logger.Warn("account activity merge failed", "error", err)
	}
	return activeness.Apply(ch, c, id, amount, now, eventAt)
}

// DNF90 optional patch: account-wide activeness
func (s *Service) mergeAccountPrivateActivity(ctx context.Context, target *repo.CharacterRecord, c *activeness.Catalog, now time.Time) error {
	if target == nil || target.AccountID == "" || c == nil {
		return nil
	}
	g, ok := s.repositoryGroup()
	if !ok || g.Character == nil {
		return nil
	}
	rows, err := g.Character.ListByAccount(ctx, target.AccountID, 32)
	if err != nil {
		return err
	}
	siblings := make([]repo.CharacterRecord, 0, len(rows))
	for _, row := range rows {
		if row.CharacterID == target.CharacterID || row.Stats["delete_flag"] != 0 {
			continue
		}
		siblings = append(siblings, row)
	}
	_, err = activeness.MergeAccountActivity(target, siblings, c, now)
	return err
}

// DNF90 optional patch: account-wide activeness
func (s *Service) mergeAccountPrivateActivityPersisted(ctx context.Context, account, character string, c *activeness.Catalog, now time.Time) error {
	if c == nil {
		return nil
	}
	g, ok := s.repositoryGroup()
	if !ok || g.Character == nil {
		return nil
	}
	rows, err := g.Character.ListByAccount(ctx, account, 32)
	if err != nil {
		return err
	}
	var target *repo.CharacterRecord
	siblings := make([]repo.CharacterRecord, 0, len(rows))
	for i := range rows {
		if rows[i].CharacterID == character {
			target = &rows[i]
			continue
		}
		if rows[i].Stats["delete_flag"] != 0 {
			continue
		}
		siblings = append(siblings, rows[i])
	}
	if target == nil {
		return nil
	}
	changed, err := activeness.MergeAccountActivity(target, siblings, c, now)
	if err != nil || !changed {
		return err
	}
	target.UpdatedAt = now
	return repo.SaveCharacterFields(ctx, g.Character, *target, repo.CharacterFieldStats)
}'''
    assert old_apply in text, "applyPrivateActivity anchor not found"
    text = text.replace(old_apply, new_apply, 1)

    old_settle = '''	key := strconv.Itoa(int(character))
	return activeness.Settle(ctx, g, c, activeness.Command{'''
    new_settle = '''	key := strconv.Itoa(int(character))
	// DNF90 optional patch: account-wide activeness
	if err := s.mergeAccountPrivateActivityPersisted(ctx, account, key, c, now); err != nil {
		return activeness.Snapshot{}, err
	}
	return activeness.Settle(ctx, g, c, activeness.Command{'''
    assert old_settle in text, "settlePrivateActivity anchor not found"
    text = text.replace(old_settle, new_settle, 1)
    path.write_text(text, encoding="utf-8")
    print(f"[patch] {path.name}")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: apply.py <ServerS5A3 source> [--check]")
        return 2
    src = Path(sys.argv[1])
    check = "--check" in sys.argv[2:]
    state = src / "go-server/internal/modules/dnf/activeness/state.go"
    bridge = src / "go-server/internal/services/dnfbridge/private_activity.go"
    for f in (state, bridge):
        if not f.is_file():
            print(f"missing {f}")
            return 1
    if check:
        ok = all(MARK in f.read_text(encoding="utf-8") for f in (state, bridge))
        print("account-wide activeness: " + ("patched" if ok else "not patched"))
        return 0 if ok else 1
    patch_state(state)
    patch_bridge(bridge)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
