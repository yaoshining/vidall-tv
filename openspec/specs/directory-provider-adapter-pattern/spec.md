## Purpose

Define the standardized `DirectoryProvider` interface and adapter pattern that decouples the directory selector UI from protocol-specific implementations (WebDAV, SMB, future protocols).

## Requirements

### Requirement: DirectoryProvider Interface Contract

The system SHALL define a standardized `DirectoryProvider` interface that all protocol-specific directory providers (SMB, WebDAV, FTP) must implement, ensuring consistent behavior and enabling seamless protocol integration.

#### Scenario: New protocols integrate using standardized interface
- **WHEN** a new protocol (e.g., FTP) needs to support directory browsing in settings
- **THEN** developer implements `DirectoryProvider` interface without modifying settings code or UI

#### Scenario: Interface methods support directory operations
- **GIVEN** a DirectoryProvider implementation
- **WHEN** settings calls listDirectory, getDisplayName, or path navigation methods
- **THEN** provider returns correct results or throws standardized error codes

#### Scenario: Error classification enables smart retry
- **WHEN** a provider operation fails
- **THEN** isRetryable() correctly classifies error as transient (retry) or fatal (show error)

### Requirement: Routing Parameter Format

The system SHALL use a standardized route parameter format to pass protocol type, source ID, and starting path to the directory selector, enabling settings to work with any protocol dynamically.

#### Scenario: Settings navigates to directory picker with protocol info
- **WHEN** user opens directory picker for SMB file source
- **THEN** route includes protocol=smb, sourceId=<uuid>, basePath=<encoded-path>

#### Scenario: Route handler instantiates correct provider
- **WHEN** route params are received
- **THEN** handler extracts protocol, loads config, instantiates SmbDirectoryProvider (or WebDAVDirectoryProvider, etc.)

#### Scenario: Path encoding preserves special characters
- **WHEN** path contains spaces or special chars (e.g., "/public/My Media")
- **THEN** basePath encodes safely for URL params and roundtrips correctly

### Requirement: DirectorySelectorContainer (Protocol-Agnostic UI)

The system SHALL use `DirectorySelectorContainer` as the protocol-agnostic UI component that accepts a `DirectoryProvider` via props, making the UI completely protocol-agnostic.

#### Scenario: Component accepts provider interface
- **WHEN** DirectorySelectorContainer receives provider prop
- **THEN** component delegates all I/O (listDirectory, getDisplayName) to provider

#### Scenario: No protocol-specific logic in UI
- **WHEN** settings uses DirectorySelectorContainer with SMB provider then WebDAV provider
- **THEN** same component works correctly with both, requiring no code changes

#### Scenario: Builder classes removed
- **WHEN** developer looks for SmbDirectorySelectorBuilder
- **THEN** class no longer exists; route handler instantiates provider directly
