library(tidyverse)
library(lubridate)
library(readxl)
library(glue)
library(httr)
library(tmaptools)
library(aws.s3)

eod_api_key <- Sys.getenv("eod_api_key")
selenium_ticker_name <- Sys.getenv("selenium_ticker_name")
merged_ticker_name <- Sys.getenv("merged_ticker_name")
voima_ticker_name <- Sys.getenv("voima_ticker_name")

transactions <- s3read_using(FUN = read_rds, bucket = Sys.getenv("bucket"),
                            object = "transactions.rds")

tickers_vec <- transactions %>% 
  filter(financial_institution != "Seligson") %>% 
  distinct(ticker) %>% 
  filter(!ticker %in% c(str_c(selenium_ticker_name, ".HE"))) %>% 
  filter(!ticker %in% voima_ticker_name) %>% 
  pluck("ticker")


read_fundamentals <- function (ticker) {
  url <- glue(str_c("https://eodhistoricaldata.com/api/fundamentals/", ticker, "?api_token={eod_api_key}"))
  
  GET(url) %>% 
    content("parsed")
}

df_raw <- map(tickers_vec, safely(read_fundamentals)) %>% 
  map(~.x$result) %>% 
  set_names(tickers_vec)

proc_general <- function (json) {
  
  var <- json$General %>% 
    discard(is.null) %>% 
    compact() %>% 
    discard(is.list) %>% 
    as_tibble()
  
}

df_raw2 <- map(df_raw, proc_general) %>%
  bind_rows(.id = "ticker") %>% 
  select(ticker, exchange = Exchange, address = Address, name = Name, exchange_country = CountryName, 
         exchange_country_iso = CountryISO, sector = Sector, industry = Industry, 
         sector_gic = GicSector, group_gic = GicGroup, industry_gic = GicIndustry, 
         subindustry_gic = GicSubIndustry, employees = FullTimeEmployees,
         updated_at = UpdatedAt) %>% 
  mutate(updated_at = parse_date(updated_at, "%Y-%m-%d"),
         postal_code = str_remove(address, ".*[\\,]") %>% str_squish(),
         state = str_extract(address, "\\s[A-Z]{1,2}\\,") %>% 
           str_extract("[A-Z]+") %>% str_squish(),
         city = str_extract(address, "(?<=\\,).*(?=\\,)") %>% 
           str_extract("[^\\,]+") %>% str_squish(),
         house_number = str_extract(address, "\\d+[\\,\\s]") %>% 
           str_extract("\\d+") %>% str_squish(),
         street = str_extract(address, "[^\\,]+") %>% str_remove_all("\\d") %>% 
           str_squish(),
         country = str_extract(address, "(?<=\\,).*(?=\\,)") %>% 
           str_remove(".*\\,") %>% str_squish()) %>% 
  mutate(country = if_else(ticker == merged_ticker_name, "United States", country),
         postal_code = if_else(ticker == merged_ticker_name, "27101", postal_code))

addresses <- df_raw2 %>% 
  transmute(address1 = str_c(street, ", ", house_number, ", ", postal_code, ", ",
                             city, ", ", country),
            address2 = str_c(street, ", ", postal_code, ", ",
                             city, ", ", country),
            address3 = str_c(street, ", ", postal_code, ", ",
                             city, ", ", country),
            address4 = str_c(house_number, ", ", street, ", ", 
                            postal_code, ", ", city, ", ", replace_na(state, ""), ", ", country),
            address5 = str_c(street, ", ", postal_code, ", ",
                            city, ", ", replace_na(state, ""), ", ", country),
            address6 = str_c(postal_code, ", ",
                            city, ", ", replace_na(state, ""), ", ", country))

geocode_with_sleep <- function (address){
  Sys.sleep(1.1)
  geocode_OSM(address)$coords
}

find_while <- function(v) {
  gc_while <- function(old, addr, ind) {
    if (!is.null(old$result)) return(old)
    list(result = quietly(geocode_with_sleep)(addr)$result, ind = ind)
  }
  reduce2(v, seq_along(v), gc_while, .init = NULL)
}

coord_raw <- mutate_all(addresses, function(x) replace_na(x, "")) %>%
  pmap(c) %>% map(safely(find_while))

df_general <- coord_raw %>%
  transpose() %>%
  as_tibble() %>%
  transmute(lon = map_dbl(result, ~.x$result["x"] %||% NA_real_),
            lat = map_dbl(result, ~.x$result["y"] %||% NA_real_)) %>%
  bind_cols(df_raw2)

general_old <- s3read_using(FUN = read_rds, bucket = Sys.getenv("bucket"),
                                         object = "fundamentals_general.rds")

general_new <- df_general %>% 
  anti_join(general_old, by = "ticker")

general_to_save <- bind_rows(general_old, general_new)

write_rds(general_to_save, file.path(tempdir(), "fundamentals_general.rds"))

put_object(
  file = file.path(tempdir(), "fundamentals_general.rds"), 
  object = "fundamentals_general.rds", 
  bucket = Sys.getenv("bucket")
)

proc_current_financials <- function (json) {
  
  var <- json$Highlights %>% 
    compact() %>% 
    as_tibble()
  
  var2 <- json$Valuation %>% 
    compact() %>% 
    as_tibble()
  
  var3 <- json$Technicals %>% 
    compact() %>% 
    as_tibble() %>% 
    select(-SharesShort, -SharesShortPriorMonth,
           -ShortRatio, -ShortPercent)
  
  var4 <- json$SharesStats %>% 
    compact() %>% 
    as_tibble()
  
  var5 <- json$AnalystRatings %>% 
    compact() %>% 
    as_tibble()
  
  bind_cols(var, var2) %>% 
    bind_cols(var3) %>% 
    bind_cols(var4)
}

df_current_financials <- map(df_raw, proc_current_financials) %>% 
  bind_rows(.id = "ticker")

current_financials_old <- s3read_using(FUN = read_rds, bucket = Sys.getenv("bucket"),
                            object = "fundamentals_current_financials.rds")

current_financials_new <- df_current_financials %>% 
  anti_join(current_financials_old, by = "ticker")

current_financials_to_save <- bind_rows(current_financials_old, current_financials_new)

write_rds(current_financials_to_save, file.path(tempdir(), "fundamentals_current_financials.rds"))

put_object(
  file = file.path(tempdir(), "fundamentals_current_financials.rds"), 
  object = "fundamentals_current_financials.rds", 
  bucket = Sys.getenv("bucket")
)

proc_earnings_history <- function (json) {
  
  var <- json$Earnings$History %>% 
    compact()
  
  map(var, ~compact(.x) %>% as_tibble()) %>%
    bind_rows()
}

proc_balance_sheet_history <- function (json) {
  
  var <- json$Financials$Balance_Sheet$quarterly %>% 
    compact()
  
  map(var, ~compact(.x) %>% as_tibble()) %>%
    bind_rows()
}

proc_income_statement_history <- function (json) {
  
  var <- json$Financials$Income_Statement$quarterly %>% 
    compact()
  
  map(var, ~compact(.x) %>% as_tibble()) %>%
    bind_rows()
}

proc_cash_flow_history <- function (json) {
  
  var <- json$Financials$Cash_Flow$quarterly %>% 
    compact()
  
  map(var, ~compact(.x) %>% as_tibble()) %>%
    bind_rows()
}

earnings <- map(df_raw, proc_earnings_history) %>% 
  bind_rows(.id = "ticker") %>% 
  select(ticker, date, reportDate, currency, everything(), -beforeAfterMarket) %>% 
  mutate(date = ymd(date),
         reportDate = ymd(reportDate)) %>% 
  mutate_at(vars(5:8), as.numeric)

balance_sheet <- map(df_raw, proc_balance_sheet_history) %>% 
  bind_rows(.id = "ticker") %>% 
  select(ticker, date, filing_date, currency_symbol, everything()) %>% 
  mutate(date = ymd(date),
         filing_date = ymd(filing_date)) %>% 
  mutate_at(vars(5:62), as.numeric)

income_statement <- map(df_raw, proc_income_statement_history) %>% 
  bind_rows(.id = "ticker") %>% 
  select(ticker, date, filing_date, currency_symbol, everything()) %>% 
  mutate(date = ymd(date),
         filing_date = ymd(filing_date)) %>% 
  mutate_at(vars(5:35), as.numeric)

cash_flow <- map(df_raw, proc_cash_flow_history) %>% 
  bind_rows(.id = "ticker") %>% 
  select(ticker, date, filing_date, currency_symbol, everything()) %>% 
  mutate(date = ymd(date),
         filing_date = ymd(filing_date)) %>% 
  mutate_at(vars(5:31), as.numeric)

## earnings

earnings_history_old <- s3read_using(FUN = read_rds, bucket = Sys.getenv("bucket"),
                                       object = "fundamentals_earnings_history.rds")

earnings_history_new <- earnings %>% 
  anti_join(earnings_history_old, by = "ticker")

earnings_history_to_save <- bind_rows(earnings_history_old, earnings_history_new)

write_rds(earnings_history_to_save, file.path(tempdir(), "fundamentals_earnings_history.rds"))

put_object(
  file = file.path(tempdir(), "fundamentals_earnings_history.rds"), 
  object = "fundamentals_earnings_history.rds", 
  bucket = Sys.getenv("bucket")
)

## balance sheet

balance_sheet_history_old <- s3read_using(FUN = read_rds, bucket = Sys.getenv("bucket"),
                                     object = "fundamentals_balance_sheet_history.rds")

balance_sheet_history_new <- balance_sheet %>% 
  anti_join(balance_sheet_history_old, by = "ticker")

balance_sheet_history_to_save <- bind_rows(balance_sheet_history_old, balance_sheet_history_new)

write_rds(balance_sheet_history_to_save, file.path(tempdir(), "fundamentals_balance_sheet_history.rds"))

put_object(
  file = file.path(tempdir(), "fundamentals_balance_sheet_history.rds"), 
  object = "fundamentals_balance_sheet_history.rds", 
  bucket = Sys.getenv("bucket")
)

## income statement

income_statement_history_old <- s3read_using(FUN = read_rds, bucket = Sys.getenv("bucket"),
                                          object = "fundamentals_income_statement_history.rds")

income_statement_history_new <- income_statement %>% 
  anti_join(income_statement_history_old, by = "ticker")

income_statement_history_to_save <- bind_rows(income_statement_history_old, income_statement_history_new)

write_rds(income_statement_history_to_save, file.path(tempdir(), "fundamentals_income_statement_history.rds"))

put_object(
  file = file.path(tempdir(), "fundamentals_income_statement_history.rds"), 
  object = "fundamentals_income_statement_history.rds", 
  bucket = Sys.getenv("bucket")
)
  
## cash flow

cash_flow_history_old <- s3read_using(FUN = read_rds, bucket = Sys.getenv("bucket"),
                                             object = "fundamentals_cash_flow_history.rds")

cash_flow_history_new <- cash_flow %>% 
  anti_join(cash_flow_history_old, by = "ticker")

cash_flow_history_to_save <- bind_rows(cash_flow_history_old, cash_flow_history_new)

write_rds(cash_flow_history_to_save, file.path(tempdir(), "fundamentals_cash_flow_history.rds"))

put_object(
  file = file.path(tempdir(), "fundamentals_cash_flow_history.rds"), 
  object = "fundamentals_cash_flow_history.rds", 
  bucket = Sys.getenv("bucket")
)
