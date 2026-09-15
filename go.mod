module github.com/tqmane/gunshot

go 1.26.0

require app v0.0.0

require (
	github.com/tink-crypto/tink-go/v2 v2.8.0 // indirect
	golang.org/x/crypto v0.55.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	google.golang.org/protobuf v1.36.12 // indirect
)

replace app => ./.build/upstream