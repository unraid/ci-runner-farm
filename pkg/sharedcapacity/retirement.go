package sharedcapacity

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	bolt "go.etcd.io/bbolt"
)

// ErrRetired prevents any ordinary client from reopening admission after a window.
var ErrRetired = errors.New("shared capacity ledger is retired")

// RetirementBinding identifies the original window and its captured native owner.
type RetirementBinding struct {
	WindowID    string `json:"windowId"`
	OwnerDigest string `json:"ownerDigest"`
}

// Retirement is retained in the original ledger; it never authorizes a new ledger.
type Retirement struct {
	Binding        RetirementBinding `json:"binding"`
	PolicyDigest   string            `json:"policyDigest"`
	SnapshotSHA256 string            `json:"snapshotSHA256"`
	RetiredAt      time.Time         `json:"retiredAt"`
}

func (binding RetirementBinding) validate() error {
	for _, value := range []string{binding.WindowID, binding.OwnerDigest} {
		decoded, err := hex.DecodeString(value)
		if err != nil || len(decoded) != sha256.Size || value != hex.EncodeToString(decoded) {
			return errors.New("retirement requires exact window and native owner digests")
		}
	}
	return nil
}

func snapshotSHA(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }

// Retire fences admission atomically after a current empty snapshot and owner
// attestation. The attestation runs under the ledger lock and must not reenter
// this broker. The owner must hold its external admission fences throughout.
func (b *Broker) Retire(policy *Policy, expected *Snapshot, binding RetirementBinding, attest func(*Snapshot) error) (Retirement, error) {
	var receipt Retirement
	if err := binding.validate(); err != nil {
		return receipt, err
	}
	if expected == nil || attest == nil {
		return receipt, errors.New("retirement requires an exact snapshot and owner attestation")
	}
	digest, err := policyDigest(policy)
	if err != nil {
		return receipt, err
	}
	expectedData, err := json.Marshal(expected)
	if err != nil {
		return receipt, err
	}
	if err = b.validatePath(false); err != nil {
		return receipt, err
	}
	db, err := bolt.Open(b.Path, 0o600, &bolt.Options{Timeout: 5 * time.Second})
	if err != nil {
		return receipt, err
	}
	defer db.Close()
	err = db.Update(func(tx *bolt.Tx) error {
		bucket := tx.Bucket([]byte("admission"))
		if bucket == nil {
			return ErrUninitialized
		}
		snapshot, readErr := readSnapshot(bucket, policy, digest, false)
		if readErr != nil {
			return readErr
		}
		current, marshalErr := json.Marshal(snapshot)
		if marshalErr != nil {
			return marshalErr
		}
		if !bytes.Equal(expectedData, current) {
			return errors.New("retirement snapshot changed")
		}
		if len(snapshot.Grants) != 0 || len(snapshot.Pending) != 0 || len(snapshot.Starts) != 0 {
			return errors.New("retirement requires settled allocations, waits and starts")
		}
		// snapshot is decoded afresh. Callback mutations cannot change the retained bytes.
		if proofErr := attest(&snapshot); proofErr != nil {
			return proofErr
		}
		receipt = Retirement{Binding: binding, PolicyDigest: digest, SnapshotSHA256: snapshotSHA(bucket.Get([]byte("snapshot"))), RetiredAt: b.now()}
		data, encodeErr := json.Marshal(receipt)
		if encodeErr != nil {
			return encodeErr
		}
		return bucket.Put([]byte("retirement"), data)
	})
	if err != nil {
		return Retirement{}, err
	}
	return receipt, nil
}

// VerifyRetired checks the original ledger and binding without enabling admission.
func (b *Broker) VerifyRetired(binding RetirementBinding) (Retirement, error) {
	var receipt Retirement
	if err := binding.validate(); err != nil {
		return receipt, err
	}
	if err := b.validatePath(false); err != nil {
		return receipt, err
	}
	db, err := bolt.Open(b.Path, 0o600, &bolt.Options{Timeout: 5 * time.Second, ReadOnly: true})
	if err != nil {
		return receipt, err
	}
	defer db.Close()
	err = db.View(func(tx *bolt.Tx) error {
		bucket := tx.Bucket([]byte("admission"))
		if bucket == nil {
			return ErrUninitialized
		}
		data := bucket.Get([]byte("retirement"))
		if data == nil {
			return errors.New("shared capacity ledger has no retirement proof")
		}
		if decodeErr := json.Unmarshal(data, &receipt); decodeErr != nil {
			return fmt.Errorf("invalid retirement proof: %w", decodeErr)
		}
		if receipt.Binding != binding || receipt.RetiredAt.IsZero() || receipt.PolicyDigest == "" || receipt.SnapshotSHA256 != snapshotSHA(bucket.Get([]byte("snapshot"))) {
			return errors.New("retirement proof differs from original ledger or window")
		}
		var original Snapshot
		if decodeErr := json.Unmarshal(bucket.Get([]byte("snapshot")), &original); decodeErr != nil {
			return decodeErr
		}
		if original.PolicyDigest != receipt.PolicyDigest || len(original.Grants) != 0 || len(original.Pending) != 0 || len(original.Starts) != 0 {
			return errors.New("retirement retained unsettled snapshot")
		}
		return validateSnapshot(&original)
	})
	if err != nil {
		return Retirement{}, err
	}
	return receipt, nil
}
