// SPDX-License-Identifier: MIT

package config

import (
	"encoding/json"
	"fmt"
)

func marshalDocument(doc Document) ([]byte, error) {
	if doc.Workspaces == nil {
		doc.Workspaces = []WorkspaceLocation{}
	}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("%w: marshal error", ErrMalformedDocument)
	}
	data = append(data, '\n')
	if int64(len(data)) > MaxDocumentBytes {
		return nil, fmt.Errorf("%w: document size exceeds limit", ErrMalformedDocument)
	}
	return data, nil
}
