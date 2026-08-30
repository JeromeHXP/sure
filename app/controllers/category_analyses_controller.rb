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
    #
    # Rollup: selecting a parent category automatically includes all its
    # subcategories (matching the IncomeStatement behavior where a parent's
    # total counts its children). We expand the selected set to include
    # children, then display only roots (plus orphan children whose parent
    # is not selected) with each parent's value summed over its children.
    parent_to_children = @all_categories.group_by(&:parent_id)

    expanded = @selected_category_ids.map(&:to_s).to_set
    @all_categories.each do |cat|
      next unless cat.parent_id.nil?
      if expanded.include?(cat.id.to_s)
        (parent_to_children[cat.id] || []).each { |child| expanded << child.id.to_s }
      end
    end
    @selected_category_ids = expanded.to_a

    selected_set = expanded
    @selected_categories = @all_categories.select { |c| selected_set.include?(c.id.to_s) }

    # Display categories: selected roots + selected children whose parent is
    # NOT selected (those show standalone instead of rolling into a parent).
    @display_categories = @all_categories.select do |c|
      if c.parent_id.nil?
        selected_set.include?(c.id.to_s)
      else
        selected_set.include?(c.id.to_s) && !selected_set.include?(c.parent_id.to_s)
      end
    end

    # Map each display category to the member category IDs that roll up to it:
    # a root includes itself + all its children; a standalone subcategory is
    # just itself.
    @member_ids_for_display = {}
    @display_categories.each do |dc|
      @member_ids_for_display[dc.id] = if dc.parent_id.nil?
        [dc.id] + (parent_to_children[dc.id] || []).map(&:id)
      else
        [dc.id]
      end
    end

    # Build monthly data for selected categories
    @monthly_data = build_monthly_category_data

    # Donut: breakdown by category for a selected month.
    # Default to the most recent month that actually has segments.
    @donut_month = parse_date_param(:donut_month)
    months_with_data = @monthly_data.select { |m| m[:segments].any? }
    if @donut_month.nil?
      @donut_month = months_with_data.any? ? months_with_data.last[:month] : @period.start_date.beginning_of_month
    end
    @donut_segments, @donut_total = build_donut_data(@donut_month)

    # Comparison vs. previous period: per-category change between the
    # current period's totals and the same-length period immediately
    # before it. Half the @monthly_data months form each half.
    @comparison_data = build_comparison_data

    # Anomaly detection: flag categories whose latest month deviates
    # significantly from their period average.
    @anomalies = build_anomaly_data

    # Top-N "where does my money go": ranking by total spend over the period.
    @top_categories = build_top_categories

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

    # Query by all selected category IDs (parents + their children).
    category_ids = @selected_categories.map(&:id)
    return months.map { |m| { month: m, month_label: I18n.l(m, format: :short_month_year), is_current: m == Date.current, segments: [], total: 0 } } if category_ids.empty?

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

    # Index raw per-(category_id, month) totals
    raw_by_key = {}
    raw_rows.each do |category_id, month_date, expense_total, income_total|
      next if month_date.nil?
      raw_by_key[[category_id, month_date.to_date]] = {
        expenses: expense_total.to_d,
        income: income_total.to_d
      }
    end

    # Aggregate by display category: each display category sums its member
    # category IDs (a root rolls up itself + children; a standalone child
    # is just itself).
    chart_data = []

    months.each do |month|
      segments = []
      total = 0

      @display_categories.each do |dc|
        member_ids = @member_ids_for_display[dc.id]
        expenses = 0
        income = 0
        member_ids.each do |mid|
          t = raw_by_key[[mid, month]]
          next unless t
          expenses += t[:expenses]
          income += t[:income]
        end

        next unless expenses > 0

        segments << {
          category_id: dc.id,
          name: dc.display_name,
          color: dc.color,
          value: expenses.to_f,
          income: income.to_f
        }
        total += expenses
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

  def build_donut_data(month)
    month_data = @monthly_data.find { |m| m[:month] == month }
    return [], 0 unless month_data && month_data[:segments].any?

    total = month_data[:total]
    segments = month_data[:segments].map do |seg|
      category = @display_categories.find { |c| c.id == seg[:category_id] }
      {
        id: seg[:category_id],
        name: seg[:name],
        amount: seg[:value],
        color: seg[:color],
        icon: category&.lucide_icon,
        percentage: total > 0 ? ((seg[:value] / total) * 100).round(1) : 0,
        clickable: false,
        currency: Current.family.currency
      }
    end.sort_by { |s| -s[:amount] }

    [ segments, total ]
  end

  def build_comparison_data
    return empty_comparison unless @period

    # Compare the current period against the equal-length period immediately
    # before it. For a 6-month window (Mar–Aug) the previous period is the
    # preceding 6 months (Sep–Feb); for YTD it's the same span last year.
    current_start = @period.start_date.beginning_of_month
    current_end = @period.end_date.end_of_month
    period_days = (current_end - current_start).to_i + 1
    prev_end = (current_start - 1.day).end_of_month
    prev_start = (prev_end - period_days.days + 1).beginning_of_month

    # All selected category IDs (parents + children) for the query
    category_ids = @selected_categories.map(&:id)
    return empty_comparison if category_ids.empty?

    # Reuse the already-computed current-period data (aggregated by display
    # category, no extra query)
    current_by_cat = Hash.new(0)
    @monthly_data.each do |m|
      m[:segments].each { |s| current_by_cat[s[:category_id]] += s[:value] }
    end

    # One grouped query for the previous period, by raw category_id
    prev_rows = Current.family.transactions
      .joins(:entry)
      .where(category_id: category_ids)
      .where(entries: { date: prev_start..prev_end, account_id: @selected_account_ids })
      .group("category_id")
      .pluck(
        "category_id",
        Arel.sql("SUM(CASE WHEN entries.amount > 0 THEN entries.amount ELSE 0 END)")
      )

    prev_raw_by_cat = Hash.new(0)
    prev_rows.each do |category_id, expense_total|
      prev_raw_by_cat[category_id] = expense_total.to_f
    end

    # Roll the previous period up by display category
    previous_by_cat = Hash.new(0)
    @display_categories.each do |dc|
      sum = 0.0
      @member_ids_for_display[dc.id].each { |mid| sum += prev_raw_by_cat[mid] }
      previous_by_cat[dc.id] = sum
    end

    # Build one row per display category that has activity in either period
    rows = @display_categories.map do |category|
      current_val = current_by_cat[category.id] || 0
      previous_val = previous_by_cat[category.id] || 0
      change = current_val - previous_val
      pct = if previous_val > 0
        ((change / previous_val) * 100).round(1)
      elsif current_val > 0
        100.0 # new spending where there was none
      else
        0.0
      end

      {
        category_id: category.id,
        name: category.display_name,
        color: category.color,
        icon: category.lucide_icon,
        current: current_val,
        previous: previous_val,
        change: change,
        pct: pct
      }
    end.reject { |r| r[:current] == 0 && r[:previous] == 0 }

    rows.sort_by! { |r| -r[:change].abs }

    current_total = current_by_cat.values.sum
    previous_total = previous_by_cat.values.sum
    total_change = current_total - previous_total
    total_pct = if previous_total > 0
      ((total_change / previous_total) * 100).round(1)
    elsif current_total > 0
      100.0
    else
      0.0
    end

    {
      rows: rows,
      current_total: current_total,
      previous_total: previous_total,
      total_change: total_change,
      total_pct: total_pct,
      available: true,
      current_label: "#{I18n.l(current_start, format: :short_month_year)} – #{I18n.l(current_end, format: :short_month_year)}",
      previous_label: "#{I18n.l(prev_start, format: :short_month_year)} – #{I18n.l(prev_end, format: :short_month_year)}"
    }
  end

  def empty_comparison
    { rows: [], current_total: 0, previous_total: 0, total_change: 0, total_pct: 0, available: false }
  end

  def build_anomaly_data
    return [] unless @monthly_data.any?

    months_with_data = @monthly_data.select { |m| m[:segments].any? }
    return [] if months_with_data.size < 2

    # Collect monthly values per category across the period
    by_category = Hash.new { |h, k| h[k] = [] }
    months_with_data.each do |m|
      m[:segments].each do |s|
        by_category[s[:category_id]] << s[:value]
      end
    end

    anomalies = []
    by_category.each do |category_id, values|
      next if values.size < 2

      latest = values.last
      rest = values[0...-1]
      avg = rest.sum / rest.size.to_f
      next if avg <= 0 && latest <= 0

      # Standard deviation of the historical months (excluding latest)
      variance = rest.map { |v| (v - avg) ** 2 }.sum / rest.size.to_f
      std = Math.sqrt(variance)

      # An anomaly: the latest month deviates from the average by more than
      # one standard deviation (or >50% if std is zero/degenerate). We also
      # require a meaningful absolute difference to avoid noise on tiny amounts.
      deviation = latest - avg
      pct_dev = avg > 0 ? (deviation / avg) * 100 : (latest > 0 ? 100 : 0)
      threshold = std > 0 ? std : avg * 0.5
      is_anomaly = deviation.abs > threshold && deviation.abs > 1

      next unless is_anomaly

      category = @display_categories.find { |c| c.id == category_id }
      next unless category

      anomalies << {
        category_id: category_id,
        name: category.display_name,
        color: category.color,
        icon: category.lucide_icon,
        latest: latest,
        average: avg.round(2),
        deviation: deviation.round(2),
        pct_dev: pct_dev.round(1),
        direction: deviation > 0 ? :up : :down
      }
    end

    anomalies.sort_by! { |a| -a[:deviation].abs }
    anomalies
  end

  def build_top_categories
    return [] unless @monthly_data.any?

    by_category = Hash.new(0)
    @monthly_data.each do |m|
      m[:segments].each { |s| by_category[s[:category_id]] += s[:value] }
    end

    total = by_category.values.sum
    return [] if total <= 0

    rows = by_category.map do |category_id, amount|
      category = @display_categories.find { |c| c.id == category_id }
      next unless category

      {
        category_id: category_id,
        name: category.display_name,
        color: category.color,
        icon: category.lucide_icon,
        amount: amount,
        percentage: ((amount / total) * 100).round(1)
      }
    end.compact

    rows.sort_by! { |r| -r[:amount] }
    { rows: rows, total: total }
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
