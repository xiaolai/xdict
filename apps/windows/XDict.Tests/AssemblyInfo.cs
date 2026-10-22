// Every test that spawns the service starts a real AppContainer process with its own storage; running classes in
// parallel starves the host and produces failures no single test can reproduce. One at a time.
using Xunit;

[assembly: CollectionBehavior(DisableTestParallelization = true)]
