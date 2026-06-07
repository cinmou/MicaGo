package send

import (
	"errors"
	"sync"
	"time"
)

var ErrDuplicateTempGUID = errors.New("duplicate tempGuid")

// PendingSendManager tracks in-flight outgoing sends and which chat.db rows
// have already been claimed by a confirmation, so two concurrent sends of
// identical text never confirm against the same row.
type PendingSendManager struct {
	mu      sync.Mutex
	pending map[string]PendingSend
	// claimed maps a matched message GUID -> the tempGUID that claimed it.
	claimed map[string]string
}

func NewPendingSendManager() *PendingSendManager {
	return &PendingSendManager{
		pending: map[string]PendingSend{},
		claimed: map[string]string{},
	}
}

// Add registers a new pending send. It stamps CreatedAt/Deadline/Status when
// they are unset so callers can pass a sparse record.
func (m *PendingSendManager) Add(p PendingSend) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, exists := m.pending[p.TempGUID]; exists {
		return ErrDuplicateTempGUID
	}
	if p.CreatedAt.IsZero() {
		p.CreatedAt = time.Now()
	}
	if p.Deadline.IsZero() && p.Timeout > 0 {
		p.Deadline = p.CreatedAt.Add(p.Timeout)
	}
	if p.Status == "" {
		p.Status = StatusPending
	}
	m.pending[p.TempGUID] = p
	return nil
}

// Remove deletes the pending send and releases any chat.db row it claimed.
func (m *PendingSendManager) Remove(tempGUID string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if p, ok := m.pending[tempGUID]; ok && p.MatchedGUID != "" {
		if owner, claimed := m.claimed[p.MatchedGUID]; claimed && owner == tempGUID {
			delete(m.claimed, p.MatchedGUID)
		}
	}
	delete(m.pending, tempGUID)
}

func (m *PendingSendManager) Has(tempGUID string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, exists := m.pending[tempGUID]
	return exists
}

// Get returns a copy of the pending send and whether it exists.
func (m *PendingSendManager) Get(tempGUID string) (PendingSend, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.pending[tempGUID]
	return p, ok
}

// List returns a snapshot of all tracked pending sends.
func (m *PendingSendManager) List() []PendingSend {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]PendingSend, 0, len(m.pending))
	for _, p := range m.pending {
		out = append(out, p)
	}
	return out
}

// Resolve atomically claims a chat.db row for a pending send and marks it
// confirmed. It returns false when the row was already claimed by a different
// pending send (so the caller should keep looking for another candidate), or
// when the tempGUID is unknown.
func (m *PendingSendManager) Resolve(tempGUID, matchedGUID string, matchedROWID int64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	p, ok := m.pending[tempGUID]
	if !ok {
		return false
	}
	if owner, claimed := m.claimed[matchedGUID]; claimed && owner != tempGUID {
		return false
	}
	m.claimed[matchedGUID] = tempGUID
	p.Status = StatusConfirmed
	p.MatchedGUID = matchedGUID
	p.MatchedROWID = matchedROWID
	m.pending[tempGUID] = p
	return true
}

// Reject marks a pending send failed with a short reason.
func (m *PendingSendManager) Reject(tempGUID, reason string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if p, ok := m.pending[tempGUID]; ok {
		p.Status = StatusFailed
		p.FailReason = reason
		m.pending[tempGUID] = p
	}
}

// ClaimedSnapshot returns a copy of the currently claimed message GUIDs so a
// matcher can exclude rows already taken by other in-flight sends.
func (m *PendingSendManager) ClaimedSnapshot() map[string]struct{} {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[string]struct{}, len(m.claimed))
	for guid := range m.claimed {
		out[guid] = struct{}{}
	}
	return out
}

// ExpireTimedOut marks every still-pending send whose deadline is before `now`
// as failed and returns them. Cleanup/removal is left to the caller; in the
// synchronous send path each request removes its own entry on completion.
func (m *PendingSendManager) ExpireTimedOut(now time.Time) []PendingSend {
	m.mu.Lock()
	defer m.mu.Unlock()
	var expired []PendingSend
	for guid, p := range m.pending {
		if p.Status != StatusPending {
			continue
		}
		if p.Deadline.IsZero() || !p.Deadline.Before(now) {
			continue
		}
		p.Status = StatusFailed
		p.FailReason = "send_confirmation_timeout"
		m.pending[guid] = p
		expired = append(expired, p)
	}
	return expired
}
