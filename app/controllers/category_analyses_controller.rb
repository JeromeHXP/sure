class CategoryAnalysesController < ApplicationController
  include Periodable

  def index
    @period_type = params[:period_type]&.to_sym || :last_6_months
    @start_date = parse_date_param(:start_date)
    @end_date = parse_date_param(:end_date)

    # Build period based on period_type
    @period = build_period_from_type

    # Accounts available for filtering (matches the dashboard money-flow widget)
    @accounts = accessible_accounts.order(:name)
    @all_account_ids = @accounts.map { |a| a.id.to_s }

    # Selected account IDs from params (default to all accessible accounts)
    raw_accounts = params[:account_ids]
    if raw_accounts.is_a?(String)
      @selected_account_ids = raw_accounts.split(",").map(&:strip).reject(&:blank?)
    else
      @selected_account_ids = Array(raw_accounts).map(&:to_s).reject(&:blank?)
    end
    @selected_account_ids = @all_account_ids if @selected_account_ids.empty?
    @all_accounts_selected = @selected_account_ids.size == @all_account_ids.size

    # Get all categories for the family
    @all_categories = Current.family.categories.alphabetically_by_hierarchy

    # Get selected category IDs from params. `category_ids` may arrive as an
    # Array (form submission with category_ids[]=), a comma-separated String
    # (built client-side), or a single value. Category IDs are UUIDs, so we
    # keep them as strings — never coerce to int (that would drop them all).
    raw = params[:category_ids]
    if raw == "none"
      @selected_category_ids = []
    elsif raw.is_a?(String)
      @selected_category_ids = raw.split(",").map(&:strip).reject(&:blank?)
    else
      @selected_category_ids = Array(raw).map(&:to_s).reject(&:blank?)
    end

    # If no categories selected, default to ALL categories (stacked per month)
    @selected_category_ids = @all_categories.pluck(:id).map(&:to_s) if @selected_category_ids.empty? && raw != "none"

    # Get selected categories, preserving the alphabetical-by-hierarchy order
    # so the chart legend and table columns are stable. Compare as strings
    # because params arrive as strings but `pluck(:id)` returns UUID objects.
    selected_set = @selected_category_ids.map(&:to_s).to_set
    @selected_categories = @all_categories.select { |c| selected_set.include?(c.id.to_s) }

    # Build monthly data for selected categories
    @monthly_data = build_monthly_category_data

    # Build category options for selector
    @category_options = build_category_options

    # Build period navigation
    @nav = build_period_navigation

    @breadcrumbs = [
      [t("breadcrumbs.home"), root_path],
      [t("breadcrumbs.category_analyses"), nil]
    ]
  end

  private

  def build_period_from_type
    case @period_type
    when :last_6_months
      start_date = (Date.current << 6).beginning_of_month
      end_date = Date.current.end_of_month
      Period.custom(start_date: ensure_date(start_date), end_date: ensure_date(end_date))
    when :last_12_months
      start_date = (Date.current << 12).beginning_of_month
      end_date = Date.current.end_of_month
      Period.custom(start_date: ensure_date(start_date), end_date: ensure_date(end_date))
    when :year_to_date
      start_date = Date.current.beginning_of_year
      end_date = Date.current
      Period.custom(start_date: ensure_date(start_date), end_date: ensure_date(end_date))
    when :last_year
      start_date = Date.current.last_year.beginning_of_year
      end_date = Date.current.last_year.end_of_year
      Period.custom(start_date: ensure_date(start_date), end_date: ensure_date(end_date))
    when :custom
      start_date = @start_date || (Date.current << 6).beginning_of_month
      end_date = @end_date || Date.current.end_of_month
      Period.custom(start_date: ensure_date(start_date), end_date: ensure_date(end_date))
    else
      # Default to last 6 months
      start_date = (Date.current << 6).beginning_of_month
      end_date = Date.current.end_of_month
      Period.custom(start_date: ensure_date(start_date), end_date: ensure_date(end_date))
    end
  end

  def ensure_date(value)
    return value if value.is_a?(Date)
    return value.to_date if value.respond_to?(:to_date)
    Date.parse(value.to_s) if value.present?
  end

  def build_monthly_category_data
    return [] unless @period

    start_date = @period.start_date.beginning_of_month
    end_date = @period.end_date.end_of_month

    # Generate all months in the period
    months = []
    current_month = start_date
    while current_month <= end_date
      months << current_month
      current_month = current_month >> 1 # Next month
    end

    # Build the selected category IDs list, ordered to match @selected_categories
    category_ids = @selected_categories.map(&:id)
    return months.map { |m| { month: m, month_label: I18n.l(m, format: :short_month_year), is_current: m == Date.current, segments: [], total: 0 } } if category_ids.empty?

    # A single grouped query: sum positive amounts (expenses) and the absolute
    # value of negative amounts (income) per category, per calendar month.
    # `entries.amount > 0` = expense, `entries.amount < 0` = income in this codebase.
    raw_rows = Current.family.transactions
      .joins(:entry)
      .where(category_id: category_ids)
      .where(entries: { date: start_date..end_date, account_id: @selected_account_ids })
      .group(Arel.sql("transactions.category_id, DATE_TRUNC('month', entries.date)"))
      .pluck(
        "category_id",
        Arel.sql("DATE_TRUNC('month', entries.date)"),
        Arel.sql("SUM(CASE WHEN entries.amount > 0 THEN entries.amount ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN entries.amount < 0 THEN ABS(entries.amount) ELSE 0 END)")
      )

    # Index results by [category_id, month] for O(1) lookup
    totals_by_key = {}
    raw_rows.each do |category_id, month_date, expense_total, income_total|
      next if month_date.nil?
      month_key = month_date.to_date
      totals_by_key[[category_id, month_key]] = {
        expenses: expense_total.to_d,
        income: income_total.to_d
      }
    end

    # Build chart data, one entry per month with all categories nested as
    # stackable segments. The chart stacks expense amounts per category so
    # the user can see where their money goes each month.
    chart_data = []

    months.each do |month|
      segments = []
      total = 0

      @selected_categories.each do |category|
        totals = totals_by_key[[category.id, month]]
        next unless totals

        # Stack expenses (the primary "where does my money go" view).
        # `.to_f` so the value serializes as a JSON number, not a string
        # (BigDecimal becomes a quoted string under as_json).
        if totals[:expenses] > 0
          segments << {
            category_id: category.id,
            name: category.display_name,
            color: category.color,
            value: totals[:expenses].to_f,
            income: totals[:income].to_f
          }
          total += totals[:expenses]
        end
      end

      chart_data << {
        month: month,
        month_label: I18n.l(month, format: :short_month_year),
        is_current: month == Date.current,
        segments: segments,
        total: total
      }
    end

    chart_data
  end

  def build_category_options
    # Group categories by parent for hierarchical display
    grouped = Category::Group.for(@all_categories)
    
    options = []
    grouped.each do |group|
      # Add parent category
      options << {
        id: group.category.id,
        name: group.category.display_name,
        color: group.category.color,
        icon: group.category.lucide_icon,
        subcategories: group.subcategories.map do |sub|
          {
            id: sub.id,
            name: sub.display_name,
            color: sub.color,
            icon: sub.lucide_icon
          }
        end
      }
    end
    
    options
  end

  def build_period_navigation
    return nil unless @period
    
    start_date = @period.start_date
    end_date = @period.end_date
    
    case @period_type
    when :last_6_months
      prev_start = (start_date << 1).to_date
      prev_end = (end_date << 1).to_date
      next_start = (start_date >> 1).to_date
      next_end = (end_date >> 1).to_date
      
      {
        prev_start: prev_start,
        prev_end: prev_end,
        next_start: next_start,
        next_end: next_end,
        label: I18n.t("category_analyses.period_labels.last_6_months", 
                      start: I18n.l(start_date, format: :short_month_year),
                      end: I18n.l(end_date, format: :short_month_year)),
        at_latest: next_start > Date.current.end_of_month
      }
    when :last_12_months
      prev_start = (start_date << 1).to_date
      prev_end = (end_date << 1).to_date
      next_start = (start_date >> 1).to_date
      next_end = (end_date >> 1).to_date
      
      {
        prev_start: prev_start,
        prev_end: prev_end,
        next_start: next_start,
        next_end: next_end,
        label: I18n.t("category_analyses.period_labels.last_12_months",
                      start: I18n.l(start_date, format: :short_month_year),
                      end: I18n.l(end_date, format: :short_month_year)),
        at_latest: next_start > Date.current.end_of_month
      }
    when :year_to_date
      prev_start = (Date.current.beginning_of_year << 12).to_date
      prev_end = (Date.current << 12).end_of_year.to_date
      
      {
        prev_start: prev_start,
        prev_end: prev_end,
        next_start: nil,
        next_end: nil,
        label: I18n.t("category_analyses.period_labels.year_to_date",
                      year: start_date.year),
        at_latest: true
      }
    when :custom
      {
        prev_start: nil,
        prev_end: nil,
        next_start: nil,
        next_end: nil,
        label: I18n.t("category_analyses.period_labels.custom",
                      start: I18n.l(start_date, format: :short),
                      end: I18n.l(end_date, format: :short)),
        at_latest: true
      }
    else
      nil
    end
  end

  def parse_date_param(key)
    return nil unless params[key].present?
    
    value = params[key]
    
    # If it's already a Date, Time, or DateTime object, convert to Date
    if value.is_a?(Date)
      return value
    elsif value.respond_to?(:to_date)
      return value.to_date
    end
    
    # Otherwise, parse from string
    begin
      parsed = value.to_s
      # If it's a datetime string, extract the date part
      if parsed.include?("T") || parsed.include?(" ")
        Date.parse(parsed.split("T").first.split(" ").first)
      else
        Date.parse(parsed)
      end
    rescue ArgumentError
      nil
    end
  end
end
