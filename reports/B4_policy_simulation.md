# B4 Policy Simulation

- Policies: P0 naive, P1 point, P2 no-unconstraining, P3 Option-B quantile policy
- Objective: fill-rate constrained comparison under LT scenarios

## Summary

| policy_name                |   lead_time_weeks |   beta_target |   fill_rate |   lost_sales_proxy |   holding_proxy |   total_cost_proxy |   n_sku |
|:---------------------------|------------------:|--------------:|------------:|-------------------:|----------------:|-------------------:|--------:|
| P0_naive_sales             |                 1 |          0.9  |    0.795064 |            15.2093 |           0     |            15.2093 |    4443 |
| P1_point_no_conformal      |                 1 |          0.9  |    0.914064 |            23.4757 |         159.734 |            39.4491 |    4443 |
| P2_no_unconstraining       |                 1 |          0.9  |    0.964145 |            16.8456 |         341.32  |            50.9776 |    4443 |
| P3_optionB_quantile_policy |                 1 |          0.9  |    0.964145 |            16.8456 |         341.32  |            50.9776 |    4443 |
| P0_naive_sales             |                 2 |          0.9  |    0.795064 |            15.2093 |           0     |            15.2093 |    4443 |
| P1_point_no_conformal      |                 2 |          0.9  |    0.914064 |            23.4757 |         159.734 |            39.4491 |    4443 |
| P2_no_unconstraining       |                 2 |          0.9  |    0.964145 |            16.8456 |         341.32  |            50.9776 |    4443 |
| P3_optionB_quantile_policy |                 2 |          0.9  |    0.964145 |            16.8456 |         341.32  |            50.9776 |    4443 |
| P0_naive_sales             |                 4 |          0.9  |    0.795064 |            15.2093 |           0     |            15.2093 |    4443 |
| P1_point_no_conformal      |                 4 |          0.9  |    0.914064 |            23.4757 |         159.734 |            39.4491 |    4443 |
| P2_no_unconstraining       |                 4 |          0.9  |    0.964145 |            16.8456 |         341.32  |            50.9776 |    4443 |
| P3_optionB_quantile_policy |                 4 |          0.9  |    0.964145 |            16.8456 |         341.32  |            50.9776 |    4443 |
| P0_naive_sales             |                 1 |          0.95 |    0.795064 |            15.2093 |           0     |            15.2093 |    4443 |
| P1_point_no_conformal      |                 1 |          0.95 |    0.914064 |            23.4757 |         159.734 |            39.4491 |    4443 |
| P2_no_unconstraining       |                 1 |          0.95 |    0.964145 |            16.8456 |         341.32  |            50.9776 |    4443 |
| P3_optionB_quantile_policy |                 1 |          0.95 |    0.974714 |            14.8295 |         424.612 |            57.2907 |    4443 |
| P0_naive_sales             |                 2 |          0.95 |    0.795064 |            15.2093 |           0     |            15.2093 |    4443 |
| P1_point_no_conformal      |                 2 |          0.95 |    0.914064 |            23.4757 |         159.734 |            39.4491 |    4443 |
| P2_no_unconstraining       |                 2 |          0.95 |    0.964145 |            16.8456 |         341.32  |            50.9776 |    4443 |
| P3_optionB_quantile_policy |                 2 |          0.95 |    0.974714 |            14.8295 |         424.612 |            57.2907 |    4443 |
| P0_naive_sales             |                 4 |          0.95 |    0.795064 |            15.2093 |           0     |            15.2093 |    4443 |
| P1_point_no_conformal      |                 4 |          0.95 |    0.914064 |            23.4757 |         159.734 |            39.4491 |    4443 |
| P2_no_unconstraining       |                 4 |          0.95 |    0.964145 |            16.8456 |         341.32  |            50.9776 |    4443 |
| P3_optionB_quantile_policy |                 4 |          0.95 |    0.974714 |            14.8295 |         424.612 |            57.2907 |    4443 |

## Gate B4

Trade-off robust pass ratio vs naive: 50.00%
PASS