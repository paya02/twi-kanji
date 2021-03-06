class Event < ApplicationRecord
  has_many :decision, :dependent => :delete_all
  has_many :member, :dependent => :delete_all

  # validates
  validates :user_id, presence: true
  validates :title, presence: true
  validates :fee, :numericality => true, :allow_blank => true

  scope :event_list, ->(user_id) {
    sql = <<-EOS
    SELECT
      e.title AS title
    , e.event_on AS event_on
    , e.start_at AS start_at
    , e.ending_at AS ending_at
    , e.fee AS fee
    , e.detail AS detail
    , e.id AS id
    , e.user_id AS user_id
    , MIN(d.day) AS min_day
    , MAX(d.day) AS max_day
    , (SELECT COUNT(*) FROM members m WHERE m.event_id = e.id) AS member_cnt
    FROM events e
    INNER JOIN decisions d
    ON e.id = d.event_id
    AND e.user_id = d.user_id
    WHERE
      (e.user_id = #{user_id} 
        OR (e.user_id != #{user_id} 
          AND EXISTS(SELECT * FROM members m WHERE m.event_id = e.id AND m.user_id = #{user_id})
        )
      )
    GROUP BY
      e.title
    , e.event_on
    , e.start_at
    , e.ending_at
    , e.fee
    , e.detail
    , e.created_at
    , e.id
    , e.user_id
    , ifnull(e.event_on, str_to_date('1000-01-01', '%Y-%M-%d'))
    ORDER BY
      ifnull(e.event_on, str_to_date('1000-01-01', '%Y-%M-%d'))
    , MIN(d.day) DESC
    , e.created_at DESC
    , e.id DESC
    EOS
    find_by_sql(sql)
  }
end
