# bee.apps.overlays

`bee.apps.overlays:app` (Overlays) is where a person reviews delivered overlay
versions and sees their activation status. It calls the Governance destination
facade `bee.gov.binding:destination_call` under `bee.gov.delivery.read`,
`bee.gov.delivery.manage` and `bee.gov.delivery.activate`. Review and selection
happen here; the approval decision belongs to the approvals owner
(`component/approvals`) and the activation owner applies the version
(`component/gov`). Singleton, listed in `bee.shell:system_menu`.
