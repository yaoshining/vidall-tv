# Entitlement Architecture

## Purpose
This capability defines the architecture and contracts for managing user entitlements and permissions in VidAll TV. It provides the foundation for feature gating and future authentication/subscription integration in v2.0.

## Requirements

### Requirement: EntitlementService Interface Contract

The system SHALL provide an EntitlementService interface defining the contract for querying user entitlements and permissions.

#### Scenario: Feature entitlement query
- **WHEN** code calls `entitlementService.hasFeature(featureId)`
- **THEN** system returns Promise<boolean> indicating whether user has access to the feature

#### Scenario: Content access query
- **WHEN** code calls `entitlementService.canAccessContent(contentId, contentType)`
- **THEN** system returns Promise<boolean> indicating whether user can access the specific content

#### Scenario: User tier query
- **WHEN** code calls `entitlementService.getUserTier()`
- **THEN** system returns Promise<'free' | 'basic' | 'premium'> indicating user's subscription tier

### Requirement: LocalFreeEntitlementService Implementation

The system SHALL provide a LocalFreeEntitlementService implementation that grants access to all features, maintaining current v1.x behavior.

#### Scenario: All features allowed
- **WHEN** LocalFreeEntitlementService.hasFeature() is called with any feature ID
- **THEN** it returns Promise resolving to true

#### Scenario: All content accessible
- **WHEN** LocalFreeEntitlementService.canAccessContent() is called with any content ID and type
- **THEN** it returns Promise resolving to true

#### Scenario: Free tier user
- **WHEN** LocalFreeEntitlementService.getUserTier() is called
- **THEN** it returns Promise resolving to 'free'

#### Scenario: Immediate promise resolution
- **WHEN** any LocalFreeEntitlementService method is called
- **THEN** returned Promise resolves synchronously (< 1ms) without async operations

### Requirement: Feature ID Naming Convention

The system SHALL enforce a consistent naming convention for feature identifiers to prevent collisions and enable discoverability.

#### Scenario: Feature ID format
- **WHEN** defining a new feature identifier
- **THEN** it MUST use format 'feature:<kebab-case-name>' (e.g., 'feature:advanced-playback')

#### Scenario: String constants for features
- **WHEN** code references feature IDs
- **THEN** it MUST use predefined string constants (e.g., FEATURE_ADVANCED_PLAYBACK) not magic strings

### Requirement: Dependency Injection Support

The system SHALL support dependency injection of EntitlementService to enable testing and future implementation swapping.

#### Scenario: Service registration at startup
- **WHEN** app initializes in Ability.onCreate()
- **THEN** EntitlementService implementation is instantiated and registered in service locator

#### Scenario: Service retrieval in components
- **WHEN** component needs entitlement checks
- **THEN** it retrieves EntitlementService from service locator without creating new instance

#### Scenario: Test mock injection
- **WHEN** running unit tests
- **THEN** mock EntitlementService can be injected to control test behavior

### Requirement: Extension Points for v2.0 Authentication

The system SHALL design architecture to support future authentication and subscription services without requiring refactoring of existing entitlement checks.

#### Scenario: Interface-based polymorphism
- **WHEN** v2.0 AuthEntitlementService is implemented
- **THEN** it implements same EntitlementService interface without changing callsites

#### Scenario: Async-ready API
- **WHEN** v2.0 service makes network calls for entitlement checks
- **THEN** existing Promise-based API handles async operations without code changes

#### Scenario: Backward compatibility
- **WHEN** swapping LocalFreeEntitlementService with AuthEntitlementService
- **THEN** no changes to business logic or UI code are required (only service registration change)

### Requirement: Error Handling Strategy

The system SHALL define clear error handling for entitlement check failures to prevent blocking user access unintentionally.

#### Scenario: v1.x fail-open policy
- **WHEN** LocalFreeEntitlementService encounters error (should never happen but defensive)
- **THEN** it logs error and returns true (allow access) to prevent blocking users

#### Scenario: Error logging for debugging
- **WHEN** entitlement check fails
- **THEN** error is logged with context (feature ID, content ID) for troubleshooting

### Requirement: Performance Requirements

The system SHALL ensure entitlement checks have minimal performance overhead.

#### Scenario: Local check latency
- **WHEN** LocalFreeEntitlementService method is called
- **THEN** it completes in < 1ms (synchronous immediate resolution)

#### Scenario: No unnecessary async overhead
- **WHEN** entitlement check is performed in v1.x
- **THEN** total overhead (including Promise creation) is < 0.1% of feature execution time

### Requirement: Documentation for Future Integration

The system SHALL provide comprehensive documentation for v2.0 developers to integrate authentication and subscription services.

#### Scenario: Migration guide available
- **WHEN** v2.0 development begins
- **THEN** docs/entitlement-integration.md exists with step-by-step migration instructions

#### Scenario: Auth service contract defined
- **WHEN** implementing v2.0 AuthEntitlementService
- **THEN** documentation specifies required network calls, caching strategy, and error handling

#### Scenario: Code examples provided
- **WHEN** developer needs to gate a new feature
- **THEN** documentation includes copy-paste examples for both hide and disable patterns
