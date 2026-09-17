// SPDX-License-Identifier: MIT

// Package config provides protected, locked, versioned local persistence for
// the Bee machine configuration document.
//
// Purpose and Boundaries:
// This package is designed for machine configuration persistence for the Bee
// LaunchPreparer. It contains:
//   - No SQL or embedded database dependencies.
//   - No Windows registry or platform registry storage.
//   - No credential provisioning, key derivation, or runtime admission.
//   - No networking, dialing, or remote discovery.
//   - No environment or global home directory resolution (the host supplies an
//     explicit private directory).
//
// Authority:
// Machine configuration relies entirely on native OS-user filesystem authority
// (owner-only permissions) enforced via internal/privatefile. Joined Hive secrets
// remain in that private file; persisting a profile does not start transport or
// admit a workspace client. Locations are remembered for launch preparation and
// may refer to paths that are temporarily unavailable.
package config
