// SPDX-License-Identifier: MIT

// Package config provides protected, locked, versioned local persistence for
// the Bee machine configuration document.
//
// Purpose and Boundaries:
// This package is designed for machine configuration persistence for the Bee
// LaunchPreparer. It contains:
//   - No SQL or embedded database dependencies.
//   - No Windows registry or platform registry storage.
//   - No credential storage or key derivation (identities are managed independently).
//   - No networking, dialing, or remote discovery.
//   - No environment or global home directory resolution (the host supplies an
//     explicit private directory).
//
// Authority:
// Machine configuration relies entirely on native OS-user filesystem authority
// (owner-only permissions) enforced via internal/privatefile. Persisting workspace
// locations or an enrollment reference grants no execution authority or network
// admission by itself. Locations are remembered for launch preparation and may
// refer to paths that are temporarily unavailable.
package config
