# CashLens Developer Guidelines

## Project Overview
CashLens is an Elixir/Phoenix application for tracking and analyzing financial transactions. It uses PostgreSQL for data storage and Phoenix LiveView for real-time UI updates.

## Tech Stack
- **Elixir 1.14+** - Programming language
- **Phoenix 1.7.21** - Web framework
- **Phoenix LiveView** - Real-time UI updates
- **Ecto** - Database interactions
- **PostgreSQL** - Database
- **TailwindCSS** - Styling
- **Ueberauth** - Authentication with Google provider
- **Docker** - Development environment

## Project Structure
- **lib/cash_lens/** - Core business logic
  - **accounts/** - User account management
  - **transactions/** - Transaction data handling
  - **parsers.ex** - Data parsing utilities
  - **transaction_parser.ex** - Transaction import logic
- **lib/cash_lens_web/** - Web interface
  - **live/** - LiveView components
  - **controllers/** - Traditional controllers
  - **components/** - Reusable UI components
- **test/** - Test files mirroring the lib/ structure
- **priv/repo/migrations/** - Database migrations

## Development Setup
1. Install dependencies: `mix setup`
2. Start PostgreSQL: `docker-compose up -d`
3. Start Phoenix server: `mix phx.server`
4. Visit [`localhost:4000`](http://localhost:4000) in your browser

## Running Tests
- Run all tests: `mix test`
- Run specific test file: `mix test test/path/to/file_test.exs`
- Run specific test: `mix test test/path/to/file_test.exs:line_number`

## Database Operations
- Create and migrate database: `mix ecto.setup`
- Reset database: `mix ecto.reset`
- Run migrations: `mix ecto.migrate`

## Asset Management
- Setup assets: `mix assets.setup`
- Build assets: `mix assets.build`
- Deploy assets: `mix assets.deploy`

## Best Practices
1. **Code Organization**
   - Keep business logic in the `cash_lens` directory
   - Keep web interface code in the `cash_lens_web` directory
   - Use contexts to group related functionality

2. **Testing**
   - Write tests for all new features
   - Use fixtures for test data
   - Test both valid and invalid scenarios

3. **Database**
   - Use migrations for all schema changes
   - Define schemas in their respective context modules
   - Use changesets for data validation

4. **UI Development**
   - Use LiveView for interactive features
   - Organize components in the components directory
   - Follow TailwindCSS conventions for styling
