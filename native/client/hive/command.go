// SPDX-License-Identifier: MIT
package hive

// DesktopCommand carries literal values. The owner resolves its admitted catalog.
type DesktopCommand struct {
	Name      string   `json:"name"`
	Arguments []string `json:"arguments"`
}

func (c DesktopCommand) Valid() bool {
	if len(c.Name) == 0 || len(c.Name) > 40 || len(c.Arguments) > 16 {
		return false
	}
	for i, b := range []byte(c.Name) {
		if !(b >= 'a' && b <= 'z') && !(i > 0 && (b >= '0' && b <= '9' || b == '_' || b == '-')) {
			return false
		}
	}
	total := 0
	for _, value := range c.Arguments {
		if len(value) > 1024 {
			return false
		}
		total += len(value)
		if total > 8192 {
			return false
		}
		for _, b := range []byte(value) {
			if b < 32 || b == 127 {
				return false
			}
		}
	}
	return true
}
