// SPDX-License-Identifier: MIT

package sqlerrors

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/mattn/go-sqlite3"
	lua "github.com/wippyai/go-lua"
)

func TestDescribeSQLiteStepAndCommitErrors(t *testing.T) {
	db, err := sql.Open("sqlite3", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, statement := range []string{
		"PRAGMA foreign_keys = ON",
		"CREATE TABLE parent (id INTEGER PRIMARY KEY)",
		"CREATE TABLE child (id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)",
		"CREATE TABLE blocked (id INTEGER)",
		"CREATE TRIGGER step_failure BEFORE INSERT ON blocked BEGIN SELECT RAISE(ABORT, 'injected SQLite step'); END",
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatal(err)
		}
	}
	_, stepErr := db.Exec("INSERT INTO blocked VALUES (1)")
	tx, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec("INSERT INTO child VALUES (1)"); err != nil {
		t.Fatal(err)
	}
	commitErr := tx.Commit()
	for name, cause := range map[string]error{"step": stepErr, "commit": commitErr} {
		t.Run(name, func(t *testing.T) {
			var native sqlite3.Error
			if cause == nil || !errors.As(cause, &native) {
				t.Fatalf("expected SQLite error, got %v", cause)
			}
			l := lua.NewState()
			defer l.Close()
			module, _ := Module.Build()
			l.SetGlobal("sqlerrors", module)
			l.SetGlobal("failure", lua.WrapErrorWithLua(l, fmt.Errorf("owning operation: %w", cause), "SQL"))
			if err := l.DoString("description = sqlerrors.describe(failure)"); err != nil {
				t.Fatal(err)
			}
			message := l.GetGlobal("description").String()
			for _, expected := range []string{cause.Error(), fmt.Sprintf("SQLite code %d", native.Code), fmt.Sprintf("extended %d", native.ExtendedCode)} {
				if !strings.Contains(message, expected) {
					t.Errorf("missing %q from %q", expected, message)
				}
			}
		})
	}
}

func TestDescribeNonSQLiteValues(t *testing.T) {
	l := lua.NewState()
	defer l.Close()
	for _, value := range []lua.LValue{lua.LNil, lua.LString("string cause"), lua.WrapErrorWithLua(l, errors.New("native cause"), "SQL")} {
		if got := describeValue(value); got != value.String() {
			t.Fatalf("changed non-SQLite cause: %q", got)
		}
	}
}
