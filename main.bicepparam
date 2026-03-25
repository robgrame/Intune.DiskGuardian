using 'main.bicep'

// REQUIRED: Object ID of the Entra group containing devices to check
param sourceGroupObjectId = 'd55e4872-e80a-4ae5-a2c2-6835d0f8cb6e'

// REQUIRED: Object ID of the Entra group where low-disk devices will be added
param entraGroupObjectId = '279b7463-1e64-4569-bdc0-2e3dca6a8595'

// Optional overrides
param logicAppName = 'logic-intune-disk-guardian'
param thresholdGB = 10
param recurrenceIntervalHours = 1
