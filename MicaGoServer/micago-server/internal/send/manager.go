package send

import (
	"errors"
	"sync"
)

var ErrDuplicateTempGUID = errors.New("duplicate tempGuid")

type PendingSendManager struct {
	mu      sync.Mutex
	pending map[string]PendingSend
}

func NewPendingSendManager() *PendingSendManager {
	return &PendingSendManager{
		pending: map[string]PendingSend{},
	}
}

func (m *PendingSendManager) Add(p PendingSend) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, exists := m.pending[p.TempGUID]; exists {
		return ErrDuplicateTempGUID
	}
	m.pending[p.TempGUID] = p
	return nil
}

func (m *PendingSendManager) Remove(tempGUID string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.pending, tempGUID)
}

func (m *PendingSendManager) Has(tempGUID string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, exists := m.pending[tempGUID]
	return exists
}
