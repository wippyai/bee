//go:build !windows || !amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"errors"
	"image"
)

var unsupported = errors.New("computer driver requires Windows amd64 in this spiral")

func openNative() error                           { return unsupported }
func closeNative()                                {}
func sessionIdentity() (string, error)            { return "", unsupported }
func size() (int, int, error)                     { return 0, 0, unsupported }
func captureNative(int, int) (*image.RGBA, error) { return nil, unsupported }
func validate(Action, int, int) error             { return unsupported }
func execute(Action) bool                         { return false }

func InputRole(string) (bool, error) { return false, nil }

func VerifyNewLogon(string) error { return unsupported }
