package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/boltdb/bolt"
)

type signed struct {
	Signed json.RawMessage `json:"signed"`
}
type rootV struct {
	Version int `json:"version"`
}
type snapV struct {
	Version int `json:"version"`
}
type targetsDoc struct {
	Signed struct {
		Version int                     `json:"version"`
		Targets map[string]json.RawMessage `json:"targets"`
	} `json:"signed"`
}

func main() {
	db, err := bolt.Open(os.Args[1], 0600, nil)
	if err != nil {
		panic(err)
	}
	defer db.Close()
	db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("tuf-client"))
		if b == nil {
			fmt.Println("no tuf-client bucket")
			return nil
	}
		b.ForEach(func(k, v []byte) error {
			switch string(k) {
			case "root.json":
				var s signed
				json.Unmarshal(v, &s)
				var r rootV
				json.Unmarshal(s.Signed, &r)
				fmt.Printf("root.json: version=%d\n", r.Version)
			case "snapshot.json":
				var s signed
				json.Unmarshal(v, &s)
				var r snapV
				json.Unmarshal(s.Signed, &r)
				fmt.Printf("snapshot.json: version=%d\n", r.Version)
			case "timestamp.json":
			var s signed
				json.Unmarshal(v, &s)
				var r struct {
					Version   int `json:"version"`
					ExpiresISO string
				}
				var full struct {
					Version  int    `json:"version"`
					Expires  string `json:"expires"`
				}
				json.Unmarshal(s.Signed, &full)
				fmt.Printf("timestamp.json: version=%d expires=%s\n", full.Version, full.Expires)
				_ = r
				_ = s
				_ = full
			case "targets.json":
				var t targetsDoc
				json.Unmarshal(v, &t)
				fmt.Printf("targets.json: version=%d n=%d\n", t.Signed.Version, len(t.Signed.Targets))
				_, ok := t.Signed.Targets["/channels/stable"]
				fmt.Printf("/channels/stable present=%v\n", ok)
				for _, p := range []string{"/flynn-host.gz", "/v20260907.1/flynn-host.gz", "/v20260904.0/flynn-host.gz"} {
					_, ok := t.Signed.Targets[p]
					fmt.Printf("  %s present=%v\n", p, ok)
				}
			default:
				fmt.Printf("%s: %d bytes\n", k, len(v))
			}
			return nil
		})
		return nil
	})
}
