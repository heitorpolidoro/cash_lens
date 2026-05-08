# Transaction Insertion Flow

This document details the processes for adding transactions to CashLens, both manually and via bank statement imports.

## 1. Manual Transaction Flow
Occurs when a user creates a transaction using the web interface form.

```mermaid
sequenceDiagram
    participant User as User (LiveView Form)
    participant Context as Transactions Context
    participant Schema as Transaction Schema
    participant DB as Database (PostgreSQL)
    participant Matcher as TransferMatcher

    User->>Context: create_transaction(attrs)
    Context->>Schema: changeset(attrs)
    Note over Schema: Generates fingerprint (hash)<br/>for deduplication
    Schema-->>Context: valid changeset
    Context->>DB: Repo.insert()
    
    alt Success (New Transaction)
        DB-->>Context: {:ok, transaction}
        Context->>Matcher: match_transfer(transaction)
        Note over Matcher: Searches for opposite transaction<br/>in another account
        Matcher-->>Context: Updates transfer links
        Context-->>User: {:ok, transaction}
    else Conflict (Duplicate)
        Note over DB: ON CONFLICT DO NOTHING
        DB-->>Context: {:ok, transaction} (existing)
        Context-->>User: {:ok, :duplicate}
    end
```

---

## 2. Statement Import Flow
Handles bulk transaction creation from files or entire directories.

```mermaid
graph TD
    A[Statements Source] --> B1[Single File Upload]
    A --> B2[Directory Scan]
    
    B1 --> C1[ImportModalComponent]
    B2 --> C2[Ingestor.import_directory/2]
    
    C1 --> D{Ingestor.import_file/2}
    C2 --> E[Loop: For each file in Dir]
    E --> D
    
    subgraph "Ingestion Processing"
        D --> F[Detect appropriate Parser]
        F --> G[Parse Transactions]
        G --> H[Loop: For each transaction]
        
        H --> I[Transactions.create_transaction/1]
        I --> J{Fingerprint Deduplication}
        
        J -->|New| K[Save to Database]
        J -->|Already exists| L[Ignore / Skip]
        
        K --> M[AutoCategorizer]
        M --> N[TransferMatcher]
    end
    
    N --> O[End of Process]
    L --> O
    O --> P[Notify User via LiveView]
```

---

## 3. Deduplication Logic (Fingerprint)
The system ensures that the same transaction is not imported multiple times by generating a unique hash.

```mermaid
flowchart LR
    A[Date] & B[Description] & C[Amount] & D[Account ID] --> E[SHA-256 Hash]
    E --> F[Unique Fingerprint]
    F --> G{Exists in DB?}
    G -->|Yes| H[Discard Insertion]
    G -->|No| I[Persist Transaction]
```

**Key Architectural Insights:**
- **Native Deduplication:** The `Transaction` schema automatically calculates the `fingerprint` in the changeset, and the database has a unique index on this field.
- **Smart Transfers:** The `TransferMatcher` attempts to link transfer legs (e.g., an exit from one account and an entry in another) right after insertion.
- **Auto-Categorization:** During import, the system tries to infer the category based on keywords defined in existing categories.
