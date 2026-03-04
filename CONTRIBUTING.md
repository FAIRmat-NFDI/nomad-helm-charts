# Contributing

## Pull Request Titles

PR titles drive the automatic changelog. Use the following prefixes so the PR is categorized correctly in the release notes:

| Prefix  | Category     | When to use                                                 |
| ------- | ------------ | ----------------------------------------------------------- |
| `feat:` | New Features | New chart values, new optional components, new capabilities |
| `fix:`  | Bug Fixes    | Template errors, incorrect defaults, broken deployments     |
| `del:`  | Removed      | Removed values, components, or features                     |

You can optionally scope the prefix to the affected chart or component:

```
feat(north): add resource limit configuration
fix(temporal): correct PostgreSQL connection defaults
del(north): remove legacy nodeSelector value
```

To exclude a PR from the changelog entirely, apply the `skip-changelog` label.
